"""Several signed-in devices per account: tokens move to their own table. Each existing token keeps working."""
import django.db.models.deletion
from django.db import migrations, models


def copy_tokens(apps, schema_editor):
    Account, Token = apps.get_model("core", "Account"), apps.get_model("core", "Token")
    Token.objects.bulk_create([Token(account=a, hash=a.token_hash) for a in Account.objects.exclude(token_hash=None)])


class Migration(migrations.Migration):

    dependencies = [
        ('core', '0005_email_password'),
    ]

    operations = [
        migrations.CreateModel(
            name='Token',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('hash', models.CharField(max_length=64, unique=True)),
                ('created', models.DateTimeField(auto_now_add=True)),
                ('account', models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name='tokens', to='core.account')),
            ],
        ),
        migrations.RunPython(copy_tokens, migrations.RunPython.noop),
        migrations.RemoveField(model_name='account', name='token_hash'),
    ]
