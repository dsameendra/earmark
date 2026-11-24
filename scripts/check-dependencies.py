"""Enforce the existing, reviewed package boundaries, including explicit integration/test adapters."""
from pathlib import Path
import re,sys
root=Path(__file__).resolve().parent.parent
approved={
 'AppCore':set(),'Persistence':{'AppCore'},'DesignSystem':{'AppCore'},'ModelStore':{'AppCore'},
 'AudioCapture':{'AppCore'},'Permissions':{'AppCore'},'Processing':{'AppCore'},'Export':{'AppCore'},
 'Meetings':{'AppCore'},'Translation':{'AppCore','NativeWorkerKit','TextGenerationNative'},'NLLBNative':{'NativeWorkerKit'},'SpeechNative':{'NativeWorkerKit'},'NativeWorkerKit':set(),'TextGenerationNative':{'NativeWorkerKit'},
 'LiveCaptions':{'AppCore','DesignSystem'},'Dictation':{'AppCore','DesignSystem','Features'},
 'Transcription':{'AppCore','AudioCapture','ModelStore'},'Diarization':{'AppCore','AudioCapture','ModelStore'},
 'QwenASR':{'AppCore','AudioCapture'},
 'Features':{'AppCore','DesignSystem','Processing','LiveCaptions','Export'},
 'Jobs':{'AppCore','Persistence','ModelStore','AudioCapture','Transcription','Processing','Export','Diarization'},
}
graph={}
for manifest in (root/'Packages').glob('*/Package.swift'):
 name=manifest.parent.name
 deps=set(re.findall(r'\.package\(path:\s*"\.\./([^"/]+)"',manifest.read_text()))
 if name not in approved or deps != approved[name]:
  sys.exit(f'{name}: unreviewed package boundary: {sorted(deps)}; expected {sorted(approved.get(name,set()))}')
 graph[name]=deps
active=set();done=set()
def visit(name):
 if name in active:sys.exit('Package dependency cycle at '+name)
 if name in done:return
 active.add(name)
 for dependency in graph[name]:visit(dependency)
 active.remove(name);done.add(name)
for name in graph:visit(name)
for file in (root/'Packages/AppCore/Sources/AppCore').glob('*.swift'):
 imports=set(re.findall(r'^import (\w+)',file.read_text(),re.M))
 if imports-{'Foundation','os'}:sys.exit(f'{file.name}: AppCore imported {imports}')
print(f'Package boundaries: {len(graph)} packages, no cycles; AppCore has no UI or vendor dependencies.')
