"""Run fresh-process native measurements sequentially; no conversions during timing."""
import argparse
import json
import subprocess
from pathlib import Path
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('config',type=Path);p.add_argument('output',type=Path);p.add_argument('--repeats',type=int,default=3)
a=p.parse_args();config=json.loads(a.config.read_text());a.output.mkdir(parents=True,exist_ok=True)
for repeat in range(a.repeats):
 for item in config['models']:
  for unit in item.get('units',['all']):
   output=a.output/f"{item['name']}-{unit}-{repeat}.json"
   if output.exists(): continue
   print(f"Running {item['name']} {unit} repeat {repeat}",flush=True)
   subprocess.run([config['benchmark'],item['model'],item['probes'],unit,str(output)],check=True)
