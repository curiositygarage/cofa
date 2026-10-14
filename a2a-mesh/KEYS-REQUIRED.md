# Credentials Required — A2A Mesh Client

| Key name | What it is for | Optional? | Where to obtain |
|----------|----------------|-----------|-----------------|
| `peers.<name>.endpoint` (config key) | Target peer A2A endpoint URLs | Depends on peers you communicate with | Your own peer registry. One entry per peer, e.g. `endpoint: http://<host>:<port>/a2a`. Not a credential — read at runtime by `a2a_client.py resolve <peer>`. |
| `my_agent_id` (config key) | Your own agent identity string sent in A2A messages | No | Your agent handle. Set by the operator in the client config during setup. |

## Note

Peer endpoints are discovered dynamically from your platform's peer registry, not hardcoded. Do not place populated peer registries in this repository — document the format instead. Real endpoints go into the deployed config file only.

## Announcement rule

If the client config is missing, or `my_agent_id` is unset in it, the component verifier
(`a2a-mesh/checks/verify.sh`) prints:

```
REQUIREDCHECK a2a-mesh-config: copy config.sample.yaml to $CONFIG and set my_agent_id + at least one peer endpoint.
```
