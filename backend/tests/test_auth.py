"""Unit tests for Supabase JWT verification (app/auth.py). Run: pytest -q"""
import time

import jwt
import pytest
from cryptography.hazmat.primitives.asymmetric import ec

from app.auth import AuthError, authenticate, issuer_for

URL = "https://example-ref.supabase.co"
SECRET = "test-secret-at-least-32-bytes-long-xxxxxxxx"
USER = "aaaaaaaa-0000-0000-0000-000000000001"


def claims(**overrides):
    now = int(time.time())
    base = {
        "sub": USER, "aud": "authenticated", "role": "authenticated",
        "iss": issuer_for(URL), "iat": now, "exp": now + 3600, "email": "jake@example.com",
    }
    base.update(overrides)
    return base


def hs(**overrides):
    return "Bearer " + jwt.encode(claims(**overrides), SECRET, algorithm="HS256")


def test_hs256_valid_token_yields_user_from_sub():
    user = authenticate(hs(), supabase_url=URL, jwt_secret=SECRET)
    assert user.user_id == USER and user.email == "jake@example.com"


def test_es256_valid_token_with_signing_key():
    key = ec.generate_private_key(ec.SECP256R1())
    token = jwt.encode(claims(), key, algorithm="ES256", headers={"kid": "k1"})
    user = authenticate("Bearer " + token, supabase_url=URL, signing_key=key.public_key())
    assert user.user_id == USER and user.access_token == token


@pytest.mark.parametrize("override, message", [
    ({"exp": int(time.time()) - 3600}, "expired"),
    ({"aud": "anon"}, "Invalid token"),
    ({"iss": "https://evil.supabase.co/auth/v1"}, "Invalid token"),
    ({"role": "anon"}, "not an authenticated user"),
])
def test_rejects_bad_claims(override, message):
    with pytest.raises(AuthError, match=message):
        authenticate(hs(**override), supabase_url=URL, jwt_secret=SECRET)


def test_rejects_wrong_signature():
    token = "Bearer " + jwt.encode(claims(), "another-secret-also-32-bytes-long-yyyy", algorithm="HS256")
    with pytest.raises(AuthError, match="Invalid token"):
        authenticate(token, supabase_url=URL, jwt_secret=SECRET)


def test_rejects_alg_none():
    token = "Bearer " + jwt.encode(claims(), None, algorithm="none")
    with pytest.raises(AuthError, match="Unsupported token algorithm"):
        authenticate(token, supabase_url=URL, jwt_secret=SECRET)


def test_rejects_hs256_when_no_secret_configured():
    with pytest.raises(AuthError, match="SUPABASE_JWT_SECRET"):
        authenticate(hs(), supabase_url=URL)


def test_es256_signed_by_foreign_key_rejected():
    ours, theirs = ec.generate_private_key(ec.SECP256R1()), ec.generate_private_key(ec.SECP256R1())
    token = jwt.encode(claims(), theirs, algorithm="ES256")
    with pytest.raises(AuthError):
        authenticate("Bearer " + token, supabase_url=URL, signing_key=ours.public_key())


@pytest.mark.parametrize("header", [None, "", "Token abc", "Bearer "])
def test_rejects_missing_or_malformed_header(header):
    with pytest.raises(AuthError):
        authenticate(header, supabase_url=URL, jwt_secret=SECRET)
