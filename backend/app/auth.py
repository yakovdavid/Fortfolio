"""End-user authentication: Supabase Auth JWT verification.

Trust model (Phase 2.1, SaaS):
  * End users (Expo client) sign in with Supabase Auth and call this API
    with `Authorization: Bearer <access_token>`. The user identity is taken
    ONLY from the verified token (`sub` claim) - never from the URL or body.
  * X-API-Key remains for internal service calls only (scheduler/admin
    operations such as /sync). It must never ship inside the client bundle.

Supported signing modes (selected automatically):
  * Asymmetric signing keys (Supabase default for new projects: ES256/RS256)
    -> verified against the project JWKS endpoint
       {SUPABASE_URL}/auth/v1/.well-known/jwks.json  (keys cached).
  * Legacy shared secret (HS256) -> used only when SUPABASE_JWT_SECRET is set.
"""
from __future__ import annotations

from dataclasses import dataclass
from functools import lru_cache
from typing import Any, Mapping, Optional

import jwt
from jwt import PyJWKClient

ASYMMETRIC_ALGORITHMS = ["ES256", "RS256", "EdDSA"]
SYMMETRIC_ALGORITHMS = ["HS256"]
EXPECTED_AUDIENCE = "authenticated"
EXPECTED_ROLE = "authenticated"
CLOCK_SKEW_SECONDS = 30


class AuthError(Exception):
    """Token missing, malformed, expired or not issued by our Supabase project."""


@dataclass(frozen=True)
class AuthenticatedUser:
    user_id: str
    email: Optional[str]
    access_token: str  # forwarded to Supabase so RLS applies to every read


def issuer_for(supabase_url: str) -> str:
    return supabase_url.rstrip("/") + "/auth/v1"


@lru_cache(maxsize=4)
def _jwks_client(jwks_url: str) -> PyJWKClient:
    return PyJWKClient(jwks_url, cache_keys=True, lifespan=3600)


def extract_bearer_token(authorization_header: Optional[str]) -> str:
    if not authorization_header:
        raise AuthError("Missing Authorization header")
    scheme, _, token = authorization_header.partition(" ")
    if scheme.lower() != "bearer" or not token.strip():
        raise AuthError("Authorization header must be 'Bearer <token>'")
    return token.strip()


def verify_supabase_jwt(
    token: str,
    *,
    supabase_url: str,
    jwt_secret: str = "",
    signing_key: Any = None,
) -> Mapping[str, Any]:
    """Verify signature, expiry, issuer, audience and role. Returns claims.

    `signing_key` lets tests (or a custom key resolver) bypass the JWKS fetch.
    """
    if not supabase_url:
        raise AuthError("SUPABASE_URL is not configured")

    try:
        header = jwt.get_unverified_header(token)
    except jwt.PyJWTError as err:
        raise AuthError(f"Malformed token: {err}") from err
    alg = header.get("alg", "")

    if alg in SYMMETRIC_ALGORITHMS:
        if not jwt_secret:
            raise AuthError("HS256 token received but SUPABASE_JWT_SECRET is not configured")
        key, algorithms = jwt_secret, SYMMETRIC_ALGORITHMS
    elif alg in ASYMMETRIC_ALGORITHMS:
        if signing_key is not None:
            key = signing_key
        else:
            jwks_url = issuer_for(supabase_url) + "/.well-known/jwks.json"
            try:
                key = _jwks_client(jwks_url).get_signing_key_from_jwt(token).key
            except jwt.PyJWTError as err:
                raise AuthError(f"Unable to resolve signing key: {err}") from err
        algorithms = ASYMMETRIC_ALGORITHMS
    else:
        # Rejects alg=none and anything unexpected.
        raise AuthError(f"Unsupported token algorithm: {alg!r}")

    try:
        claims = jwt.decode(
            token,
            key=key,
            algorithms=algorithms,
            audience=EXPECTED_AUDIENCE,
            issuer=issuer_for(supabase_url),
            leeway=CLOCK_SKEW_SECONDS,
            options={"require": ["exp", "sub", "aud", "iss"]},
        )
    except jwt.ExpiredSignatureError as err:
        raise AuthError("Token expired") from err
    except jwt.PyJWTError as err:
        raise AuthError(f"Invalid token: {err}") from err

    if claims.get("role") != EXPECTED_ROLE:
        raise AuthError("Token is not an authenticated user session")
    return claims


def authenticate(
    authorization_header: Optional[str],
    *,
    supabase_url: str,
    jwt_secret: str = "",
    signing_key: Any = None,
) -> AuthenticatedUser:
    token = extract_bearer_token(authorization_header)
    claims = verify_supabase_jwt(
        token, supabase_url=supabase_url, jwt_secret=jwt_secret, signing_key=signing_key
    )
    return AuthenticatedUser(user_id=str(claims["sub"]), email=claims.get("email"), access_token=token)
