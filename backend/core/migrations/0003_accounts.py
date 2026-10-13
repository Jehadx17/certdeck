"""Multi-user: accounts, per-user doc ids, media ownership. Everything that exists becomes the owner's.

The owner's token is the current CERTDECK_API_TOKEN, so phones keep working without re-entering it.
The doc table is rebuilt (its primary key was the doc id, which now repeats across users), keeping every seq.
"""
import hashlib
import re

import django.db.models.deletion
from django.conf import settings
from django.db import migrations, models

MEDIA_NAME = re.compile(r"[0-9a-f]{64}\.(png|jpg|jpeg|webp|gif)")


def create_owner(apps, schema_editor):
    Account = apps.get_model("core", "Account")
    token = settings.CERTDECK_API_TOKEN
    owner = Account.objects.create(name="owner", role="owner",
                                   token_hash=hashlib.sha256(token.encode()).hexdigest() if token else None)
    apps.get_model("core", "AiCall").objects.update(user=owner)
    media_dir = settings.CERTDECK_MEDIA_DIR
    names = [p.name for p in media_dir.iterdir() if MEDIA_NAME.fullmatch(p.name)] if media_dir.is_dir() else []
    apps.get_model("core", "Media").objects.bulk_create([apps.get_model("core", "Media")(user=owner, name=n) for n in names])


def copy_docs(apps, schema_editor):
    Old, New = apps.get_model("core", "Doc"), apps.get_model("core", "UserDoc")
    owner = apps.get_model("core", "Account").objects.get(role="owner")
    batch = []
    for d in Old.objects.order_by("seq").iterator(chunk_size=1000):
        batch.append(New(user=owner, doc_id=d.id, kind=d.kind, data=d.data, updated_at=d.updated_at,
                         deleted=d.deleted, seq=d.seq))
        if len(batch) == 1000:
            New.objects.bulk_create(batch)
            batch = []
    New.objects.bulk_create(batch)


class Migration(migrations.Migration):
    dependencies = [("core", "0002_aicall_cost_batch")]

    operations = [
        migrations.CreateModel(
            name="Account",
            fields=[
                ("id", models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
                ("name", models.CharField(max_length=64, unique=True)),
                ("role", models.CharField(default="student", max_length=16)),
                ("token_hash", models.CharField(max_length=64, null=True, unique=True)),
                ("cap_usd", models.DecimalField(blank=True, decimal_places=2, max_digits=8, null=True)),
                ("active", models.BooleanField(default=True)),
                ("created", models.DateTimeField(auto_now_add=True)),
            ],
        ),
        migrations.AddField(
            model_name="aicall", name="user",
            field=models.ForeignKey(null=True, on_delete=django.db.models.deletion.SET_NULL, to="core.account"),
        ),
        migrations.CreateModel(
            name="Media",
            fields=[
                ("id", models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
                ("name", models.CharField(max_length=80)),
                ("user", models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, to="core.account")),
            ],
            options={"constraints": [models.UniqueConstraint(fields=("user", "name"), name="media_user_name")]},
        ),
        migrations.RunPython(create_owner, migrations.RunPython.noop),
        migrations.CreateModel(
            name="UserDoc",
            fields=[
                ("id", models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
                ("doc_id", models.CharField(max_length=64)),
                ("kind", models.CharField(db_index=True, max_length=32)),
                ("data", models.JSONField()),
                ("updated_at", models.BigIntegerField()),
                ("deleted", models.BooleanField(default=False)),
                ("seq", models.BigIntegerField(unique=True)),
                ("user", models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name="docs",
                                           to="core.account")),
            ],
            options={"constraints": [models.UniqueConstraint(fields=("user", "doc_id"), name="doc_user_doc_id")]},
        ),
        migrations.RunPython(copy_docs, migrations.RunPython.noop),
        migrations.DeleteModel(name="Doc"),
        migrations.RenameModel(old_name="UserDoc", new_name="Doc"),
    ]
