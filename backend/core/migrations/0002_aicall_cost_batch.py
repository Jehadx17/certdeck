from django.db import migrations, models

# Opus 5.5 $/MTok at the time: input, 5m cache write, cache read, output. Earlier rows were all Opus 5.5.
RATES = (4, 5, 0.20, 20)


def backfill(apps, schema_editor):
    for row in apps.get_model("core", "AiCall").objects.all():
        tokens = (row.input_tokens, row.cache_creation_tokens, row.cache_read_tokens, row.output_tokens)
        row.cost_usd = round(sum(t * r for t, r in zip(tokens, RATES)) / 1e6, 6)
        row.save(update_fields=["cost_usd"])


class Migration(migrations.Migration):
    dependencies = [("core", "0001_initial")]

    operations = [
        migrations.AddField("aicall", "cost_usd", models.DecimalField(decimal_places=6, default=0, max_digits=10)),
        migrations.AddField("aicall", "batch", models.BooleanField(default=False)),
        migrations.RunPython(backfill, migrations.RunPython.noop),
    ]
