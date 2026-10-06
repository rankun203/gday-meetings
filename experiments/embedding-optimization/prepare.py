"""Tokenize an explicit private retrieval corpus; write token IDs only to ignored output."""
import argparse
import hashlib
import json
import time
from pathlib import Path
from transformers import AutoTokenizer
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('tokenizer',type=Path);p.add_argument('dataset',type=Path);p.add_argument('output',type=Path)
a=p.parse_args();a.output.mkdir(parents=True,exist_ok=True)
queries=[json.loads(x) for x in (a.dataset/'queries.jsonl').read_text().splitlines()]
corpus=[json.loads(x) for x in (a.dataset/'corpus.jsonl').read_text().splitlines()]
tokenizer=AutoTokenizer.from_pretrained(a.tokenizer,local_files_only=True)
rows=[];lengths=[];times=[]
for text in [q['query'] for q in queries]+[c['transcript_evidence'] for c in corpus]:
 start=time.perf_counter();ids=tokenizer.encode(text,add_special_tokens=True);times.append((time.perf_counter()-start)*1000);lengths.append(len(ids))
 # Fixed-shape parity evaluates the same deterministic 512-token truncation for every variant.
 encoded=tokenizer(text,padding='max_length',max_length=512,truncation=True)
 rows.append({'ids':encoded['input_ids'],'mask':encoded['attention_mask']})
(a.output/'full-512.json').write_text(json.dumps(rows)+'\n')
short=[{'ids':r['ids'][:128],'mask':r['mask'][:128]} for r,n in zip(rows[:len(queries)],lengths) if n<=128]
(a.output/'queries-128.json').write_text(json.dumps(short)+'\n')
manifest={'queryCount':len(queries),'passageCount':len(corpus),'queryLengths':lengths[:len(queries)],
 'queriesOver128':sum(n>128 for n in lengths[:len(queries)]),'inputsOver512':sum(n>512 for n in lengths),
 'tokenizationP50Ms':sorted(times)[len(times)//2],'tokenizationP95Ms':sorted(times)[int(len(times)*.95)],
 'sha256':{f:hashlib.sha256((a.dataset/f).read_bytes()).hexdigest() for f in ['queries.jsonl','corpus.jsonl']}}
(a.output/'inputs.json').write_text(json.dumps(manifest,indent=2)+'\n')
print(json.dumps({k:v for k,v in manifest.items() if k!='queryLengths'}))
