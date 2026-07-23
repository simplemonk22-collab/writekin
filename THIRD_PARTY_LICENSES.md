# Third-Party Licenses

Writekin builds on the following open-source software, each governed by
its own license:

| Dependency | License | Source |
|---|---|---|
| mlx-swift | MIT | https://github.com/ml-explore/mlx-swift |
| mlx-swift-lm | MIT | https://github.com/ml-explore/mlx-swift-lm |
| GRDB.swift | MIT | https://github.com/groue/GRDB.swift |
| swift-transformers | Apache-2.0 | https://github.com/huggingface/swift-transformers |
| swift-huggingface | Apache-2.0 | https://github.com/huggingface/swift-huggingface |
| Sparkle | MIT | https://github.com/sparkle-project/Sparkle |

## Runtime-downloaded tools (not distributed with Writekin)

| Tool | License | Source |
|---|---|---|
| imessage-exporter | GPL-3.0 | https://github.com/ReagentX/imessage-exporter |

imessage-exporter is downloaded on demand by the user's machine directly
from the project's official GitHub releases (checksum-verified), invoked
as a separate process, and never bundled in or linked into Writekin.

## Model weights

Language-model weights are downloaded by the user from Hugging Face and
are governed by their respective model licenses (see each model's page;
the built-in manifest lists Qwen-family models under Apache-2.0).
