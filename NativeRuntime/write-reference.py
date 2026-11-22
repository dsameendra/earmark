"""Development only: regenerate native tokenizer/inference goldens from the pinned Python reference."""
import hashlib,json,pathlib,sys
import ctranslate2
import sentencepiece
folder=pathlib.Path(sys.argv[1])
assert ctranslate2.__version__ == '4.6.0'
assert sentencepiece.__version__ == '0.2.1'
sp=sentencepiece.SentencePieceProcessor(model_file=str(folder/'sentencepiece.bpe.model'))
translator=ctranslate2.Translator(str(folder),device='cpu',compute_type='int8',intra_threads=4)
texts=['Hello, world!','ශ්‍රී ලංකාව ගැන අපි කතා කරනවා.','  Good\tmorning\n everyone.  ','සිංහල + English 2026','caf\u00e9 cafe\u0301']
cases=[('eng_Latn','sin_Sinh','Good morning everyone.'),('eng_Latn','sin_Sinh','The meeting starts in five minutes.'),('sin_Sinh','eng_Latn','සුබ උදෑසනක් හැමෝටම.'),('sin_Sinh','eng_Latn','අපි හෙට හමුවෙමු.')]
rows=[]
for src,tgt,text in cases:
 result=translator.translate_batch([[src]+sp.encode(text,out_type=str)[:500]+['</s>']],target_prefix=[[tgt]],beam_size=4,max_decoding_length=256)
 rows.append(dict(source=src,target=tgt,text=text,translation=sp.decode(result[0].hypotheses[0][1:])))
def sha(path):
 h=hashlib.sha256()
 with path.open('rb') as f:
  for chunk in iter(lambda:f.read(1024*1024),b''):h.update(chunk)
 return h.hexdigest()
out=dict(ctranslate2=ctranslate2.__version__,sentencepiece=sentencepiece.__version__,modelSHA256=sha(folder/'model.bin'),tokenizerSHA256=sha(folder/'sentencepiece.bpe.model'),tokens=[dict(text=t,pieces=sp.encode(t,out_type=str)) for t in texts],translations=rows)
path=pathlib.Path('Packages/NLLBNative/Tests/NLLBNativeTests/Fixtures/parity.json')
path.write_text(json.dumps(out,ensure_ascii=False,indent=2)+'\n');print(path)
