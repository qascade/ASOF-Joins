#include "postgres.h"

#include "access/nbtree.h"
#include "executor/executor.h"
#include "executor/nodeAsofjoin.h"
#include "miscadmin.h"
#include "utils/lsyscache.h"

/*
 * Compare the equality keys of an outer row and an inner row, in the order
 * the planner sorted the inputs.
 *
 *   < 0  outer comes first  -> no inner row with this key yet; stop
 *   = 0  same key            -> candidate
 *   > 0  inner comes first   -> inner row is too early; skip it
 *
 * NULL keys are ordered by the sort's NULLS FIRST/LAST setting, so an inner
 * row with a NULL key is skipped or stops the scan, and never matches.
 */
static int
asof_compare_keys(AsofJoinState *node, TupleTableSlot *outerslot,
				  TupleTableSlot *innerslot)
{
	ExprContext *econtext = node->js.ps.ps_ExprContext;

	econtext->ecxt_outertuple = outerslot;
	econtext->ecxt_innertuple = innerslot;

	for (int i = 0; i < node->aj_NumKeys; i++)
	{
		Datum		outerval;
		Datum		innerval;
		bool		outernull;
		bool		innernull;
		int			cmp;

		outerval = ExecEvalExpr(node->aj_OuterKeys[i], econtext, &outernull);
		innerval = ExecEvalExpr(node->aj_InnerKeys[i], econtext, &innernull);

		cmp = ApplySortComparator(outerval, outernull,
								  innerval, innernull,
								  &node->aj_KeySorts[i]);
		if (cmp != 0)
			return cmp;
	}
	return 0;
}

/* Does the outer row have a NULL in any equality key?  Then it can't match. */
static bool
asof_outer_key_is_null(AsofJoinState *node, TupleTableSlot *outerslot)
{
	ExprContext *econtext = node->js.ps.ps_ExprContext;

	econtext->ecxt_outertuple = outerslot;

	for (int i = 0; i < node->aj_NumKeys; i++)
	{
		bool		isnull;

		(void) ExecEvalExpr(node->aj_OuterKeys[i], econtext, &isnull);
		if (isnull)
			return true;
	}
	return false;
}

/* Is the match condition (t.ts >= q.ts) true?  NULL counts as false. */
static bool
asof_cond_holds(AsofJoinState *node, TupleTableSlot *outerslot,
				TupleTableSlot *innerslot)
{
	ExprContext *econtext = node->js.ps.ps_ExprContext;

	econtext->ecxt_outertuple = outerslot;
	econtext->ecxt_innertuple = innerslot;
	return ExecQual(node->aj_AsofCond, econtext);
}

/* Move the inner cursor ("the finger") to the next inner row. */
static void
asof_advance_inner(AsofJoinState *node)
{
	TupleTableSlot *slot = ExecProcNode(innerPlanState(node));

	if (TupIsNull(slot))
	{
		node->aj_InnerSlot = NULL;
		node->aj_InnerDone = true;
	}
	else
		node->aj_InnerSlot = slot;
}

/* Forget the remembered best inner row. */
static void
asof_clear_best(AsofJoinState *node)
{
	ExecClearTuple(node->aj_BestSlot);
	node->aj_HaveBest = false;
}

/*
 * ExecAsofJoin
 *
 * Both inputs arrive sorted by (equality keys, match column) ascending.
 * Each call returns one output row: the next outer row, joined to the latest
 * inner row with the same keys that satisfies the match condition, or to
 * NULLs if there is none.  The inner cursor only ever moves forward.
 */
static TupleTableSlot *
ExecAsofJoin(PlanState *pstate)
{
	AsofJoinState *node = castNode(AsofJoinState, pstate);
	ExprContext *econtext = node->js.ps.ps_ExprContext;

	for (;;)
	{
		TupleTableSlot *outerslot;
		TupleTableSlot *matchslot = NULL;

		CHECK_FOR_INTERRUPTS();

		/* free memory used while producing the previous row */
		ResetExprContext(econtext);

		/* next outer row; none left means the join is finished */
		outerslot = ExecProcNode(outerPlanState(node));
		if (TupIsNull(outerslot))
			return NULL;

		/* rule 1: a NULL key never matches */
		if (!asof_outer_key_is_null(node, outerslot))
		{
			/* rule 3: best belongs to an earlier key group -> forget it */
			if (node->aj_HaveBest &&
				asof_compare_keys(node, outerslot, node->aj_BestSlot) != 0)
				asof_clear_best(node);

			/* first call: put the finger on the first inner row */
			if (node->aj_InnerSlot == NULL && !node->aj_InnerDone)
				asof_advance_inner(node);

			/* rules 2 and 4: slide the finger forward */
			while (!node->aj_InnerDone)
			{
				int			cmp = asof_compare_keys(node, outerslot,
													node->aj_InnerSlot);

				if (cmp > 0)
				{
					/* rule 2: inner key is smaller, no outer row wants it */
					asof_advance_inner(node);
				}
				else if (cmp == 0 &&
						 asof_cond_holds(node, outerslot, node->aj_InnerSlot))
				{
					/* rule 4: qualifies -> COPY it, then move on */
					ExecCopySlot(node->aj_BestSlot, node->aj_InnerSlot);
					node->aj_HaveBest = true;
					asof_advance_inner(node);
				}
				else
					break;		/* later key, or too late in time: stop */
			}

			/* rule 5: re-check best against this outer row */
			if (node->aj_HaveBest &&
				asof_cond_holds(node, outerslot, node->aj_BestSlot))
				matchslot = node->aj_BestSlot;
		}

		/* build the output row: outer + best, or outer + NULLs */
		econtext->ecxt_outertuple = outerslot;
		econtext->ecxt_innertuple = matchslot ? matchslot
			: node->aj_NullInnerSlot;

		/* WHERE quals filter the joined row */
		if (ExecQual(node->js.ps.qual, econtext))
			return ExecProject(node->js.ps.ps_ProjInfo);

		InstrCountFiltered1(node, 1);
	}
}

/*
 * Issue #11 handles only the narrow case: >=, LEFT join, one equality key,
 * and no extra ON conditions.  Everything else is left to the LATERAL
 * rewrite (enable_asofjoin_native = off).
 */

static bool
asof_is_supported(AsofJoin *node)
{
	return node->join.jointype == JOIN_ASOF_LEFT &&
		!node->asof_descending &&
		!node->asof_strict &&
		list_length(node->mergeclauses) == 1 &&
		node->join.joinqual == NIL;
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
