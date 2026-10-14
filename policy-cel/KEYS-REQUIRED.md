# Credentials Required — Policy Layer (CEL)

| Key name | What it is for | Optional? | Where to obtain |
|----------|----------------|-----------|-----------------|
| *none* | This component is configuration-only. It evaluates local CEL rule files stored on disk. No external credentials, API keys, or tokens are required. | — | — |

## Note

The CEL engine reads rule files from the local filesystem. Ensure the rules directory is readable by the process that runs the evaluator. If deploying in a restricted environment, verify filesystem permissions rather than obtaining any credential.
