# Tiny Extension Examples

Each example is a normal Python file using only the standard library and the
public HTTP protocol. Run one from an open cmdy checkout:

```sh
cmdy extension dev Examples/Extensions/01_hello_command.py
```

The default development grants cover events, pane reading, commands, panels,
Surfaces, and notifications. Hook and pane-control examples show the extra
grants they need in their header. Channel connectors request `channels` plus
`events.read`; the header in example 11 has the exact command.

| File | Demonstrates |
|---|---|
| `01_hello_command.py` | Register and receive a palette command |
| `02_task_surface.py` | Native task Surface |
| `03_git_table.py` | Structured table plus canonical command text |
| `04_protect_force_push.py` | Cancel a command decision |
| `05_clean_paste.py` | Replace pasted text |
| `06_quiet_notifications.py` | Notification policy hook |
| `07_attention_switcher.py` | Read and focus panes |
| `08_deploy_form.py` | Native form and mutating confirmation |
| `09_diff_surface.py` | Native diff Surface |
| `10_command_history.py` | Stable rows and sequenced patches |
| `11_demo_channel.py` | Register a Channel, ingest a Work Item, deliver and acknowledge replies |

These examples are intentionally direct. The Swift SDK offers typed models, but
it receives no additional authority.
