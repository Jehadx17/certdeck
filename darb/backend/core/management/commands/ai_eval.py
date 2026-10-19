import json
from datetime import date
from pathlib import Path

from django.conf import settings
from django.core.management.base import BaseCommand, CommandError

from core import evals

REPORT = Path(settings.BASE_DIR).parent.parent / "docs" / "DARB-AI-EVAL.md"


class Command(BaseCommand):
    help = "Runs the AI eval (old Opus/Sonnet setup vs Haiku, judged blind by Opus) and writes docs/DARB-AI-EVAL.md."

    def add_arguments(self, parser):
        parser.add_argument("features", nargs="*", help="explain grade cards reteach (default: all)")
        parser.add_argument("--raw", help="also save every output to this JSON file")
        parser.add_argument("--from", dest="src", help="rebuild the report from a --raw file (no API calls)")

    def handle(self, *args, features=None, raw=None, src=None, **options):
        if src:
            results = json.loads(Path(src).read_text())
        elif not settings.ANTHROPIC_API_KEY:
            raise CommandError("ANTHROPIC_API_KEY is not set")
        else:
            results = evals.run(features or None, log=self.stdout.write)
        if raw:
            Path(raw).write_text(json.dumps(results, ensure_ascii=False, indent=1, default=str))
        summary = evals.summarize(results)
        sess = evals.session_cost(summary)
        judge_usd = sum(r.get("judge_usd", 0) for rows in results.values() for r in rows)
        run_usd = judge_usd + sum(r["base_usd"] + r["cand_usd"] for rows in results.values() for r in rows)
        lines = [f"# Darb: AI eval report ({date.today().isoformat()})", "",
                 "Each runtime feature on CertDeck's setup (Opus writes, Sonnet reads; medium effort) and on Darb's "
                 f"(**{evals.ai.MODEL}**, low effort, tight max_tokens), on the fixed set in `darb/backend/core/eval_set.json`. "
                 f"{evals.JUDGE} scored each pair blind and in random order; grading is checked against hand-set gold "
                 f"scores. Pass rules: judged overall >= {evals.MIN_SCORE}, at most {evals.MAX_DROP} below the old setup, "
                 f"at most {evals.MAX_WRONG} item judged incorrect; grading mean error <= {evals.GRADE_MAE} and verdict "
                 f"agreement >= {evals.GRADE_AGREE:.0%}; Arabic language >= {evals.ARABIC_MIN}. Re-run: "
                 "`manage.py ai_eval`.", "",
                 "| feature | n | old setup | Haiku | Haiku $/call | old $/call | Haiku s | result |",
                 "|---|---|---|---|---|---|---|---|"]
        for f, s in summary.items():
            if f == "arabic":
                lines.append(f"| Arabic quality (all Arabic outputs) | {s['n']} | | language {s['haiku_language']:.2f} | | | | "
                             f"{'**pass**' if s['pass'] else '**FAIL**'} |")
            elif f == "grade":
                lines.append(f"| grade | {s['n']} | MAE {s['base_mae']:.3f}, agree {s['base_agree']:.0%} | MAE {s['haiku_mae']:.3f}, "
                             f"agree {s['haiku_agree']:.0%} | {s['haiku_usd_per_call']:.5f} | {s['base_usd_per_call']:.5f} | "
                             f"{s['haiku_s']:.1f} | {'**pass**' if s['pass'] else '**FAIL**'} |")
            else:
                lines.append(f"| {f} | {s['n']} | {s['base_overall']:.2f} (wrong {s['base_wrong']}) | {s['cand_overall']:.2f} "
                             f"(correct {s['cand_correct']:.2f}, wrong {s['cand_wrong']}) | {s['haiku_usd_per_call']:.5f} | "
                             f"{s['base_usd_per_call']:.5f} | {s['haiku_s']:.1f} | {'**pass**' if s['pass'] else '**FAIL**'} |")
        lines += ["", "## Cost per typical session (measured Haiku prices)",
                  f"- Free session (1 explanation + 1 graded answer): **${sess['free_session']:.5f}**; 20 sessions/month: "
                  f"${sess['free_month_20_sessions']:.4f} (free cap ${evals.ai.Config.get().free_cap_usd}).",
                  f"- Plus session (3 explanations, 2 graded answers, a daily re-teach, 10 uploaded pages a week): "
                  f"**${sess['plus_session']:.5f}**; 20 sessions/month: ${sess['plus_month_20_sessions']:.4f} "
                  f"(Plus cap ${evals.ai.Config.get().paid_cap_usd}).",
                  f"- This eval run cost ${run_usd:.2f} (judge ${judge_usd:.2f}).", ""]
        report = REPORT if REPORT.parent.is_dir() else Path("/tmp/DARB-AI-EVAL.md")  # no docs/ inside the container
        report.write_text("\n".join(lines))
        self.stdout.write(f"wrote {report}")
