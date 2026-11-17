"""Release audit through the existing patch-and-verify xtool_build pipeline."""
import importlib.util
import os
import sys
from pathlib import Path

root=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('xtool_flow',root/'scripts/xtool_build.py')
flow=importlib.util.module_from_spec(spec)
spec.loader.exec_module(flow)

def release_build():
    if os.name=='nt':
        location=flow.win_to_wsl_path(root)
        command=['wsl','-d','Ubuntu','--','bash','-lc',f"cd '{location}' && /usr/local/bin/xtool dev build --ipa --configuration release"]
    else: command=['/usr/local/bin/xtool','dev','build','--ipa','--configuration','release']
    flow.run_step('Build Release IPA with xtool',command)

flow.run_xtool_ipa_build=release_build
sys.argv=[sys.argv[0],'--skip-preflight']
sys.exit(flow.main())
