"""Convert pinned Granite encoders with controlled precision and optional palettes."""
import argparse
import importlib.util
import json
import subprocess
import time
from pathlib import Path

import coremltools as ct
import numpy as np
import torch
from transformers import AutoModel, AutoTokenizer

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('granite_conversion', ROOT / 'tools/semantic-model-conversion/scripts/convert_granite_coreml.py')
base = importlib.util.module_from_spec(spec)
spec.loader.exec_module(base)


def use_fp16(op):
    # Keep mask sentinels and probability/normalization arithmetic out of fp16.
    return op.op_type not in {'select', 'add', 'softmax', 'layer_norm', 'reduce_l2', 'real_div'}


def use_bounded_fp16(op):
    return op.op_type not in {'select', 'clip', 'reduce_l2', 'real_div'}


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('model', choices=base.MODELS)
    p.add_argument('output', type=Path)
    p.add_argument('--cache', type=Path, required=True)
    p.add_argument('--tokens', type=int, default=512)
    p.add_argument('--precision', choices=['fp32', 'selective', 'bounded-mask'], default='selective')
    p.add_argument('--palette', type=int, choices=[4,6,8])
    p.add_argument('--from-package', type=Path)
    a = p.parse_args()
    a.output.mkdir(parents=True, exist_ok=False)
    torch.set_num_threads(2)
    torch.manual_seed(0)
    name, revision = base.MODELS[a.model]
    source = a.cache / ('models--' + name.replace('/', '--')) / 'snapshots' / revision
    start = time.perf_counter()
    if a.from_package:
        converted = ct.models.MLModel(str(a.from_package), skip_model_load=True)
    else:
        tokenizer = AutoTokenizer.from_pretrained(source, local_files_only=True)
        model = AutoModel.from_pretrained(source, local_files_only=True, dtype=torch.float32, attn_implementation='eager').eval()
        model.config.reference_compile = False
        if a.precision == 'bounded-mask':
            # Experiment-only override for this pinned ModernBERT implementation.
            # A finite sentinel avoids overflow when attention arithmetic casts to fp16.
            original_mask = model._update_attention_mask
            def bounded_mask(attention_mask, output_attentions):
                masks = original_mask(attention_mask, output_attentions)
                return tuple(mask.clamp(min=-10000.0) for mask in masks)
            model._update_attention_mask = bounded_mask
        encoder = base.Encoder(model).eval()
        encoded = tokenizer(base.PROBES[0], return_tensors='pt', padding='max_length', max_length=a.tokens)
        with torch.no_grad():
            traced = torch.jit.trace(encoder, (encoded['input_ids'], encoded['attention_mask']), strict=True)
        converted = ct.convert(traced, convert_to='mlprogram', minimum_deployment_target=ct.target.macOS15,
            inputs=[ct.TensorType(name=k, shape=(1,a.tokens), dtype=np.int32) for k in ['input_ids','attention_mask']],
            outputs=[ct.TensorType(name='embedding', dtype=np.float32)],
            compute_precision=ct.precision.FLOAT32 if a.precision == 'fp32' else ct.transform.FP16ComputePrecision(
                op_selector=use_bounded_fp16 if a.precision == 'bounded-mask' else use_fp16),
            skip_model_load=True)
    if a.palette:
        import coremltools.optimize.coreml as opt
        converted = opt.palettize_weights(converted, opt.OptimizationConfig(global_config=opt.OpPalettizerConfig(
            nbits=a.palette, mode='kmeans', weight_threshold=2048, num_kmeans_workers=2)))
    converted.author = 'IBM Granite; Core ML conversion'
    converted.license = 'Apache-2.0'
    converted.save(str(a.output/'SemanticEncoder.mlpackage'))
    subprocess.run(['xcrun','coremlcompiler','compile',str(a.output/'SemanticEncoder.mlpackage'),str(a.output)],check=True)
    report = {'model':name,'revision':revision,'tokens':a.tokens,'precision':a.precision,'palette':a.palette,
              'seconds':time.perf_counter()-start,'packageBytes':sum(p.stat().st_size for p in (a.output/'SemanticEncoder.mlpackage').rglob('*') if p.is_file())}
    (a.output/'conversion.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report),flush=True)

if __name__ == '__main__': main()
