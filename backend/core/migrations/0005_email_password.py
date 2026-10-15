from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('core', '0004_login_code'),
    ]

    operations = [
        migrations.RemoveField(model_name='account', name='login_code_expires'),
        migrations.RemoveField(model_name='account', name='login_code_hash'),
        migrations.AddField(model_name='account', name='email', field=models.EmailField(blank=True, max_length=254, null=True, unique=True)),
        migrations.AddField(model_name='account', name='password', field=models.CharField(blank=True, max_length=128)),
    ]
