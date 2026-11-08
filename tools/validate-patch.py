import os, sys, yaml

path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.expanduser('~'), '.dsh', 'profiles', 'desktop', 'cordis.patch.yml')

try:
    with open(path, encoding='utf-8') as f:
        data = yaml.safe_load(f)
except Exception as e:
    print("PARSE_ERROR:", e)
    sys.exit(2)

if not isinstance(data, list):
    print("STRUCT_ERROR: root is not a YAML list, got", type(data).__name__)
    sys.exit(3)

ids = []
for i, item in enumerate(data):
    if not isinstance(item, dict):
        print(f"STRUCT_ERROR: entry[{i}] is not a mapping")
        sys.exit(4)
    ids.append(item.get('id'))

print("PARSE_OK   entries =", len(data))
print("ids =", ", ".join(str(x) for x in ids))

for item in data:
    if item.get('id') == 'llm-pi-ai':
        cfg = item.get('config') or {}
        provs = cfg.get('providers') or {}
        if not isinstance(provs, dict):
            print("STRUCT_ERROR: providers is not a mapping")
            sys.exit(5)
        print("providers =", ", ".join(provs.keys()))
        for name, pcfg in provs.items():
            if not isinstance(pcfg, dict):
                print(f"  STRUCT_ERROR: provider '{name}' is not a mapping")
                sys.exit(6)
            models = pcfg.get('models') or []
            mid = [m.get('id') for m in models if isinstance(m, dict)]
            print(f"  {name}: api={pcfg.get('api')} baseURL={pcfg.get('baseURL')} "
                  f"apiKeyEnv={pcfg.get('apiKeyEnv')} models={mid}")

