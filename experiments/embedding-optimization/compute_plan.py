"""Record planned compute devices; this is not a runtime execution trace."""
import argparse
import json
from collections import Counter
from pathlib import Path
import coremltools as ct
from coremltools.models.compute_plan import MLComputePlan
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('model');p.add_argument('output',type=Path);p.add_argument('--units',default='ALL')
a=p.parse_args()
plan=MLComputePlan.load_from_path(a.model,compute_units=getattr(ct.ComputeUnit,a.units))
counts=Counter();costs=Counter();unknown=0
for function in plan.model_structure.program.functions.values():
    stack=list(function.block.operations)
    while stack:
        op=stack.pop()
        for b in op.blocks: stack.extend(b.operations)
        usage=plan.get_compute_device_usage_for_mlprogram_operation(op)
        device=type(usage.preferred_compute_device).__name__ if usage else 'unknown'
        counts[device]+=1
        cost=plan.get_estimated_cost_for_mlprogram_operation(op)
        if cost: costs[device]+=cost.weight
        else: unknown+=1
result={'allowedComputeUnits':a.units,'plannedOperationCounts':dict(counts),'estimatedCostByDevice':dict(costs),'operationsWithoutCost':unknown}
a.output.write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result))
