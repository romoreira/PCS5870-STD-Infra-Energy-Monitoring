#!/usr/bin/env python3
import sys,yaml
docs=[]
for d in yaml.safe_load_all(sys.stdin):
    if d is None:continue
    if not isinstance(d,dict) or not d.get('kind'):sys.exit('Unexpected non-resource YAML')
    if d['kind']=='DaemonSet':
        spec=d['spec']['template']['spec'];spec['hostPID']=True
        spec['dnsPolicy']='ClusterFirstWithHostNet'
        for c in spec.get('containers',[]):
            c['startupProbe'].update({'failureThreshold':30,'periodSeconds':5,'timeoutSeconds':3})
    docs.append(d)
yaml.safe_dump_all(docs,sys.stdout,sort_keys=False)
