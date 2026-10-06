"""Compare local vectors and retrieval against one fixed-shape FP32 baseline."""
import argparse
import json
from pathlib import Path
import numpy as np

def vectors(path):
 d=json.loads(Path(path).read_text())
 if d['nonfiniteValues']: raise ValueError('Non-finite vectors cannot be scored')
 v=np.asarray(d['vectors'],dtype=np.float64)
 norm=np.linalg.norm(v,axis=1,keepdims=True)
 if np.any(norm==0): raise ValueError('Zero embedding')
 return v/norm

def main():
 p=argparse.ArgumentParser(description=__doc__)
 p.add_argument('dataset',type=Path);p.add_argument('baseline',type=Path);p.add_argument('candidate',type=Path)
 p.add_argument('output',type=Path);p.add_argument('--query-only',action='store_true')
 p.add_argument('--documents',type=Path,help='Full query+passage native output supplying candidate documents for a short-query encoder')
 a=p.parse_args()
 queries=[json.loads(x) for x in (a.dataset/'queries.jsonl').read_text().splitlines()]
 corpus=[json.loads(x) for x in (a.dataset/'corpus.jsonl').read_text().splitlines()]
 n=len(queries);b=vectors(a.baseline);c=vectors(a.candidate)
 assert len(b)==n+len(corpus)
 assert len(c)==(n if a.query_only else len(b))
 lookup={row['segment_id']:i for i,row in enumerate(corpus)}
 assert len(lookup)==len(corpus), 'Duplicate passage identifiers'
 positives=[{lookup[p['window_id']] for p in q['positives']} for q in queries]
 assert all(positives), 'Every evaluated query must have labeled evidence'
 reference=np.argsort(-(b[:n]@b[n:].T),axis=1,kind='stable')
 def stats(ranks):
  hit1=[];hit5=[];recall5=[];mrr=[]
  for row,pos in zip(ranks,positives):
   if not pos: continue
   hit1.append(int(row[0] in pos));hit5.append(int(bool(set(row[:5])&pos)))
   recall5.append(len(set(row[:5])&pos)/len(pos))
   mrr.append(1/(next(i for i,x in enumerate(row) if x in pos)+1))
  return {'labeledQueries':len(hit1),'hitAt1':float(np.mean(hit1)),'hitAt5':float(np.mean(hit5)),
          'evidenceRecallAt5':float(np.mean(recall5)),'MRR':float(np.mean(mrr))}
 result={'baseline':stats(reference),'queryCount':n,'passageCount':len(corpus)}
 modes=[('mixed',b[n:])]
 if a.documents:
  assert a.query_only, '--documents requires --query-only'
  documents=vectors(a.documents)
  assert len(documents)==len(b)
  modes.append(('reindexed',documents[n:]))
 elif not a.query_only:
  modes.append(('reindexed',c[n:]))
 for mode,passages in modes:
  ranks=np.argsort(-(c[:n]@passages.T),axis=1,kind='stable')
  result[mode]={**stats(ranks),'top1Agreement':float(np.mean(ranks[:,0]==reference[:,0])),
   'top5Overlap':float(np.mean([len(set(x[:5])&set(y[:5]))/5 for x,y in zip(ranks,reference)]))}
 paired=b[:len(c)]
 cos=(paired*c).sum(axis=1)
 result['embeddingAgreement']={'minimumCosine':float(cos.min()),'meanCosine':float(cos.mean()),
  'p01Cosine':float(np.quantile(cos,.01)),'maximumComponentError':float(np.abs(paired-c).max())}
 a.output.write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result))
if __name__=='__main__':main()
