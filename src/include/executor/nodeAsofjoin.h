#ifndef NODEASOFJOIN_H
#define NODEASOFJOIN_H

#include "nodes/execnodes.h"

extern AsofJoinState *ExecInitAsofJoin(AsofJoin *node, EState *estate, int eflags);
extern void ExecEndAsofJoin(AsofJoinState *node);

#endif							/* NODEASOFJOIN_H */
