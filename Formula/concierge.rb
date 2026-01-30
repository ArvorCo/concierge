class Concierge < Formula
  desc "Concierge: secure WhatsApp orchestration for molt.bot and agent workflows"
  homepage "https://github.com/arvorco/concierge"
  head "https://github.com/arvorco/concierge.git"

  depends_on "elixir"
  depends_on "erlang"
  depends_on "sqlite"

  def install
    ENV["MIX_ENV"] = "prod"

    system "mix", "deps.get"
    system "mix", "release"

    libexec.install Dir["_build/prod/rel/concierge/*"]

    (bin/"concierged-daemon").write <<~SH
      #!/bin/bash
      set -euo pipefail
      REL_BIN="#{libexec}/bin/concierge"
      "$REL_BIN" daemon >/dev/null 2>&1 || "$REL_BIN" start >/dev/null 2>&1 || true
      while true; do
        if ! "$REL_BIN" pid >/dev/null 2>&1; then
          "$REL_BIN" daemon >/dev/null 2>&1 || "$REL_BIN" start >/dev/null 2>&1 || true
        fi
        sleep 5
      done
    SH

    (bin/"concierged").write <<~SH
      #!/bin/bash
      set -euo pipefail
      exec "#{bin}/concierged-daemon"
    SH

    (bin/"concierge").write <<~SH
      #!/bin/bash
      set -euo pipefail
      CONCIERGE_HOME="${CONCIERGE_HOME:-$(pwd)}"
      mkdir -p "$CONCIERGE_HOME/commands"
      ts=$(date +%s%N)
      cmd=${1:-}
      case "$cmd" in
        reprocess-all) printf '%s\n' '{"action":"reprocess_all"}' > "$CONCIERGE_HOME/commands/command-${ts}.json" ;;
        reset-all)     printf '%s\n' '{"action":"reset_all"}' > "$CONCIERGE_HOME/commands/command-${ts}.json" ;;
        reprocess)     printf '%s\n' "{\"action\":\"reprocess\",\"jid\":\"${2:-}\"}" > "$CONCIERGE_HOME/commands/command-${ts}.json" ;;
        reset)         printf '%s\n' "{\"action\":\"reset\",\"jid\":\"${2:-}\"}" > "$CONCIERGE_HOME/commands/command-${ts}.json" ;;
        *) echo "Usage: concierge {reprocess-all|reset-all|reprocess <jid>|reset <jid>}" ;;
      esac
    SH

    chmod 0755, bin/"concierged-daemon"
    chmod 0755, bin/"concierged"
    chmod 0755, bin/"concierge"
  end
end
