from scripts.normalize_azure_storage_secret import parse_credential


def test_parse_account_key():
    cred = parse_credential("ZmFrZUFjY291bnRLZXkxMjM0NTY=", "demoacct")
    assert cred.storage_account == "demoacct"
    assert "AccountKey=ZmFrZUFjY291bnRLZXkxMjM0NTY=" in cred.connection_string
    assert cred.account_key == "ZmFrZUFjY291bnRLZXkxMjM0NTY="
    assert cred.sas_token is None


def test_parse_connection_string():
    raw = "DefaultEndpointsProtocol=https;AccountName=cnpgdemo;AccountKey=abcd;EndpointSuffix=core.windows.net"
    cred = parse_credential(raw, "ignored")
    assert cred.storage_account == "cnpgdemo"
    assert "AccountName=cnpgdemo" in cred.connection_string
    assert cred.account_key == "abcd"


def test_parse_sas_token():
    token = "?sv=2021-10-04&ss=bf&srt=sco&sp=rl&sig=fakesignature"
    cred = parse_credential(token, "demoacct")
    assert cred.sas_token == token.lstrip("?")
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
