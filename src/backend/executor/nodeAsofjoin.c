#include "postgres.h"

#include "access/nbtree.h"
#include "executor/executor.h"
#include "executor/nodeAsofjoin.h"
#include "miscadmin.h"
#include "utils/lsyscache.h"


static TupleTableSlot *
ExecAsofJoin(PlanState *pstate)
{

	elog(ERROR, "ASOF JOIN executor loop is not written yet");
	return NULL;				/* keep compiler quiet */
}

/*
 * Issue #11 handles only the narrow case: >=, LEFT join, one equality key.
 * Everything else is left to the LATERAL rewrite (enable_asofjoin_native = off).
 */
static bool
asof_is_supported(AsofJoin *node)
{
	return node->join.jointype == JOIN_ASOF_LEFT &&
		!node->asof_descending &&
		!node->asof_strict &&
		list_length(node->mergeclauses) == 1;
}

/*
 * Prepare each equality key (Merge Cond): how to read it from an outer row,
 * how to read it from an inner row, and how to compare the two (<, =, >)
 * in the same order the planner sorted the inputs.  Same recipe as
 * MJExamineQuals() in nodeMergejoin.c.
 */
static void
asof_setup_keys(AsofJoinState *asofstate, AsofJoin *node)
{
	int			nkeys = list_length(node->mergeclauses);
	int			i = 0;
	ListCell   *lc;

	asofstate->aj_NumKeys = nkeys;
	asofstate->aj_OuterKeys = palloc0(nkeys * sizeof(ExprState *));
	asofstate->aj_InnerKeys = palloc0(nkeys * sizeof(ExprState *));
	asofstate->aj_KeySorts = palloc0(nkeys * sizeof(SortSupportData));

	foreach(lc, node->mergeclauses)
	{
		OpExpr	   *clause = lfirst_node(OpExpr, lc);
		SortSupport ssup = &asofstate->aj_KeySorts[i];
		Oid			opfamily = node->mergeFamilies[i];
		int			strategy;
		Oid			lefttype;
		Oid			righttype;
		Oid			sortfunc;

		/* left arg reads the outer row, right arg reads the inner row */
		asofstate->aj_OuterKeys[i] =
			ExecInitExpr(linitial(clause->args), (PlanState *) asofstate);
		asofstate->aj_InnerKeys[i] =
			ExecInitExpr(lsecond(clause->args), (PlanState *) asofstate);

		/* the comparator must follow the planner's sort order */
		ssup->ssup_cxt = CurrentMemoryContext;
		ssup->ssup_collation = node->mergeCollations[i];
		ssup->ssup_reverse = node->mergeReversals[i];
		ssup->ssup_nulls_first = node->mergeNullsFirst[i];
		ssup->abbreviate = false;

		get_op_opfamily_properties(clause->opno, opfamily, false,
								   &strategy, &lefttype, &righttype);

		/* prefer the fast sort-support comparator ... */
		sortfunc = get_opfamily_proc(opfamily, lefttype, righttype,
									 BTSORTSUPPORT_PROC);
		if (OidIsValid(sortfunc))
			OidFunctionCall1(sortfunc, PointerGetDatum(ssup));

		/* ... and fall back to the plain btree compare function */
		if (ssup->comparator == NULL)
		{
			sortfunc = get_opfamily_proc(opfamily, lefttype, righttype,
										 BTORDER_PROC);
			if (!OidIsValid(sortfunc))
				elog(ERROR, "missing support function %d(%u,%u) in opfamily %u",
					 BTORDER_PROC, lefttype, righttype, opfamily);
			PrepareSortSupportComparisonShim(sortfunc, ssup);
		}

		i++;
	}
}

AsofJoinState *
ExecInitAsofJoin(AsofJoin *node, EState *estate, int eflags)
{
	AsofJoinState *asofstate;
	TupleDesc	innerDesc;

	/* we only ever walk forward: no backward scan, no mark/restore */
	Assert(!(eflags & (EXEC_FLAG_BACKWARD | EXEC_FLAG_MARK)));

	/* Outside the narrow case: plain EXPLAIN is fine, running is not */
	if (!asof_is_supported(node) && !(eflags & EXEC_FLAG_EXPLAIN_ONLY))
		ereport(ERROR,
				(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
				 errmsg("ASOF JOIN executor is not implemented yet"),
				 errhint("Set enable_asofjoin_native to off to run the query as a LATERAL join.")));

	asofstate = makeNode(AsofJoinState);
	asofstate->js.ps.plan = (Plan *) node;
	asofstate->js.ps.state = estate;
	asofstate->js.ps.ExecProcNode = ExecAsofJoin;
	asofstate->js.jointype = node->join.jointype;

	/* memory/scratch space for evaluating expressions */
	ExecAssignExprContext(estate, &asofstate->js.ps);

	/* the two children: outer = left (trades), inner = right (quotes) */
	outerPlanState(asofstate) = ExecInitNode(outerPlan(node), estate, eflags);
	innerPlanState(asofstate) = ExecInitNode(innerPlan(node), estate, eflags);
	innerDesc = ExecGetResultType(innerPlanState(asofstate));

	/* output row slot, and projection of the SELECT list */
	ExecInitResultTupleSlotTL(&asofstate->js.ps, &TTSOpsVirtual);
	ExecAssignProjectionInfo(&asofstate->js.ps, NULL);

	/* WHERE quals (filter results) and other ON quals (filter candidates) */
	asofstate->js.ps.qual =
		ExecInitQual(node->join.plan.qual, (PlanState *) asofstate);
	asofstate->js.joinqual =
		ExecInitQual(node->join.joinqual, (PlanState *) asofstate);

	/* the match condition, t.ts >= q.ts */
	asofstate->aj_AsofCond =
		ExecInitQual(list_make1(node->asofclause), (PlanState *) asofstate);

	/* equality keys, t.sym = q.sym */
	asof_setup_keys(asofstate, node);

	/*
	 * BestSlot is our OWN storage: a minimal-tuple slot that keeps a private
	 * copy, so it survives the inner child overwriting its own slot.
	 */
	asofstate->aj_BestSlot =
		ExecInitExtraTupleSlot(estate, innerDesc, &TTSOpsMinimalTuple);

	/* all-NULL inner row for outer rows with no match (LEFT join) */
	asofstate->aj_NullInnerSlot =
		ExecInitNullTupleSlot(estate, innerDesc, &TTSOpsVirtual);

	/* cursor state: nothing fetched yet */
	asofstate->aj_InnerSlot = NULL;
	asofstate->aj_InnerDone = false;
	asofstate->aj_HaveBest = false;

	return asofstate;
}






void
ExecEndAsofJoin(AsofJoinState *node)
{
	ExecEndNode(innerPlanState(node));
	ExecEndNode(outerPlanState(node));
}
