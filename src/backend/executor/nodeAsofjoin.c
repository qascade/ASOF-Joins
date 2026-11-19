#include "postgres.h"

#include "executor/executor.h"
#include "executor/nodeAsofjoin.h"

static TupleTableSlot *
ExecAsofJoin(PlanState *pstate)
{
	/* ExecInitAsofJoin errors out unless this is EXPLAIN, so never here */
	elog(ERROR, "ASOF JOIN executor is not implemented yet");
	return NULL;				/* keep compiler quiet */
}

AsofJoinState *
ExecInitAsofJoin(AsofJoin *node, EState *estate, int eflags)
{
	AsofJoinState *asofstate;

	/* Plain EXPLAIN is fine; actually running the join is not */
	if (!(eflags & EXEC_FLAG_EXPLAIN_ONLY))
		ereport(ERROR,
				(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
				 errmsg("ASOF JOIN executor is not implemented yet"),
				 errhint("Set enable_asofjoin_native to off to run the query as a LATERAL join.")));

	asofstate = makeNode(AsofJoinState);
	asofstate->js.ps.plan = (Plan *) node;
	asofstate->js.ps.state = estate;
	asofstate->js.ps.ExecProcNode = ExecAsofJoin;
	asofstate->js.jointype = node->join.jointype;

	/* Set up the two inputs so EXPLAIN can show them */
	outerPlanState(asofstate) = ExecInitNode(outerPlan(node), estate, eflags);
	innerPlanState(asofstate) = ExecInitNode(innerPlan(node), estate, eflags);

	return asofstate;
}

void
ExecEndAsofJoin(AsofJoinState *node)
{
	ExecEndNode(innerPlanState(node));
	ExecEndNode(outerPlanState(node));
}
