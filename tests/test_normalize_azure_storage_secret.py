import json

from scripts.normalize_azure_storage_secret import parse_credential


def test_parse_account_key():
    cred = parse_credential("ZmFrZUFjY291bnRLZXkxMjM0NTY=", "demoacct")
    assert cred.storage_account == "demoacct"
    assert "AccountKey=ZmFrZUFjY291bnRLZXkxMjM0NTY=" in cred.connection_string
    assert cred.account_key == "ZmFrZUFjY291bnRLZXkxMjM0NTY="
    assert cred.sas_token is None


def test_parse_account_key_with_quotes():
    cred = parse_credential('"ZmFrZUFjY291bnRLZXkxMjM0NTY="', "demoacct")
    assert cred.account_key == "ZmFrZUFjY291bnRLZXkxMjM0NTY="


def test_parse_connection_string():
    raw = "DefaultEndpointsProtocol=https;AccountName=cnpgdemo;AccountKey=abcd;EndpointSuffix=core.windows.net"
    cred = parse_credential(raw, "ignored")
    assert cred.storage_account == "cnpgdemo"
    assert "AccountName=cnpgdemo" in cred.connection_string
    assert cred.account_key == "abcd"


def test_parse_connection_string_with_newlines():
    raw = "DefaultEndpointsProtocol=https\nAccountName=cnpgdemo\nAccountKey=abcd\nEndpointSuffix=core.windows.net"
    cred = parse_credential(raw, "ignored")
    assert cred.storage_account == "cnpgdemo"
    assert "AccountName=cnpgdemo" in cred.connection_string
    assert "EndpointSuffix=core.windows.net" in cred.connection_string


def test_parse_single_account_key_pair():
    raw = "AccountKey=ZmFrZUFjY291bnRLZXkxMjM0NTY="
    cred = parse_credential(raw, "demoacct")
    assert cred.account_key == "ZmFrZUFjY291bnRLZXkxMjM0NTY="
    assert cred.storage_account == "demoacct"


def test_parse_single_sas_pair():
    raw = "SharedAccessSignature=sv=2021-10-04&sig=fake"
    cred = parse_credential(raw, "demoacct")
    assert cred.sas_token == "sv=2021-10-04&sig=fake"
    assert "SharedAccessSignature=sv=2021-10-04&sig=fake" in cred.connection_string


def test_parse_sas_token():
    token = "?sv=2021-10-04&ss=bf&srt=sco&sp=rl&sig=fakesignature"
    cred = parse_credential(token, "demoacct")
    assert cred.sas_token == token.lstrip("?")
    assert "SharedAccessSignature=" in cred.connection_string


def test_parse_sas_token_with_different_order():
    token = "sp=racwdl&st=2024-01-01T00%3A00%3A00Z&se=2024-12-31T23%3A59%3A59Z&sv=2021-10-04&sig=anotherfake"
    cred = parse_credential(token, "demoacct")
    assert cred.sas_token == token
    assert "SharedAccessSignature=" in cred.connection_string


def test_parse_sas_connection_string():
    raw = (
        "BlobEndpoint=https://example.blob.core.windows.net/;"
        "QueueEndpoint=https://example.queue.core.windows.net/;"
        "SharedAccessSignature=sv=2021-10-04&sig=fake"
    )
    cred = parse_credential(raw, "demoacct")
    assert cred.storage_account == "demoacct"
    assert cred.sas_token == "sv=2021-10-04&sig=fake"
    assert "BlobEndpoint=https://example.blob.core.windows.net/" in cred.connection_string
    assert "QueueEndpoint=https://example.queue.core.windows.net/" in cred.connection_string


def test_parse_sas_url():
    token = "sv=2021-10-04&sig=fake"
    url = f"https://cnpgdemo.blob.core.windows.net/backups?{token}"
    cred = parse_credential(url, "ignored")
    assert cred.storage_account == "cnpgdemo"
    assert cred.sas_token == token
    assert "BlobEndpoint=https://cnpgdemo.blob.core.windows.net/" in cred.connection_string


def test_parse_connection_string_json_wrapper():
    raw = '{"connectionString": "DefaultEndpointsProtocol=https;AccountName=cnpgdemo;AccountKey=abcd;EndpointSuffix=core.windows.net"}'
    cred = parse_credential(raw, "ignored")
    assert cred.storage_account == "cnpgdemo"
    assert cred.account_key == "abcd"


def test_parse_key_list_json_wrapper():
    raw = '[{"value": "ZmFrZUFjY291bnRLZXkxMjM0NTY="}]'
    cred = parse_credential(raw, "demoacct")
    assert cred.account_key == "ZmFrZUFjY291bnRLZXkxMjM0NTY="


def test_parse_key_dict_with_keys_field():
    raw = '{"keys": [{"value": "ZmFrZUFjY291bnRLZXkxMjM0NTY="}]}'
    cred = parse_credential(raw, "demoacct")
    assert cred.account_key == "ZmFrZUFjY291bnRLZXkxMjM0NTY="


def test_parse_nested_json_wrappers():
    raw = json.dumps(
        {
            "data": {
                "properties": {
                    "value": {
                        "connectionString": "DefaultEndpointsProtocol=https;AccountName=cnpgdemo;AccountKey=abcd;EndpointSuffix=core.windows.net",
                    }
                }
            }
        }
    )
    cred = parse_credential(raw, "ignored")
    assert cred.storage_account == "cnpgdemo"
    assert cred.account_key == "abcd"


def test_parse_development_storage_connection_string():
    raw = "UseDevelopmentStorage=true"
    cred = parse_credential(raw, "devstoreaccount1")
    assert cred.connection_string == "UseDevelopmentStorage=true"
    assert cred.storage_account == "devstoreaccount1"
    assert cred.account_key is None


def test_parse_yaml_style_pairs():
    raw = """
    AccountName: cnpgdemo
    AccountKey: abcd1234==
    BlobEndpoint: https://cnpgdemo.blob.core.windows.net/
    """
    cred = parse_credential(raw, "fallback")
    assert cred.storage_account == "cnpgdemo"
    assert cred.account_key == "abcd1234=="
    assert "BlobEndpoint=https://cnpgdemo.blob.core.windows.net/" in cred.connection_string
