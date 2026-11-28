## What and why

<!-- What does this change, and why? Link any related issue. -->
<!-- Before posting, run tools/check_pr_text.py on the proposed title/body. Keep internal distribution records and approvals private. -->

## Checks

- [ ] `flutter analyze --no-pub --fatal-infos` and `flutter test --no-pub` pass
- [ ] `python tools/check_docs.py` and `python tools/privacy_check.py` pass
- [ ] Playbook, setup guide or troubleshooting updated if behavior changed
- [ ] No API keys, real messages, private hostnames, signing files or personal paths
- [ ] PR title and description preflighted; no private distribution references or run approvals
- [ ] Stays read-only, keeps TLS validation, and adds no on-device mail cache
