"""Credentials and JWT token management for App Store Connect API."""

import os
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional

import jwt
import yaml


@dataclass
class Credentials:
    key_id: str
    issuer_id: str
    private_key: str
    bundle_id: Optional[str] = None
    app_id: Optional[str] = None

    @classmethod
    def from_yaml(cls, path: str | Path) -> "Credentials":
        path = Path(path)
        with open(path) as f:
            config = yaml.safe_load(f)

        asc = config["app_store_connect"]
        key_id = asc["key_id"]
        issuer_id = asc["issuer_id"]

        if "private_key_content" in asc:
            private_key = asc["private_key_content"]
        elif "private_key_file" in asc:
            key_path = Path(asc["private_key_file"])
            if not key_path.is_absolute():
                key_path = path.parent / key_path
            private_key = key_path.read_text()
        else:
            raise ValueError("credentials.yml must have private_key_content or private_key_file")

        app_config = config.get("app", {})
        return cls(
            key_id=key_id,
            issuer_id=issuer_id,
            private_key=private_key,
            bundle_id=app_config.get("bundle_id"),
            app_id=app_config.get("app_id"),
        )

    @classmethod
    def from_env(cls) -> "Credentials":
        key_id = os.environ["ASC_KEY_ID"]
        issuer_id = os.environ["ASC_ISSUER_ID"]

        if "ASC_PRIVATE_KEY" in os.environ:
            private_key = os.environ["ASC_PRIVATE_KEY"]
        elif "ASC_PRIVATE_KEY_FILE" in os.environ:
            private_key = Path(os.environ["ASC_PRIVATE_KEY_FILE"]).read_text()
        else:
            raise ValueError("Set ASC_PRIVATE_KEY or ASC_PRIVATE_KEY_FILE")

        return cls(
            key_id=key_id,
            issuer_id=issuer_id,
            private_key=private_key,
            bundle_id=os.environ.get("ASC_BUNDLE_ID"),
            app_id=os.environ.get("ASC_APP_ID"),
        )

    @classmethod
    def load(cls, yaml_path: Optional[str | Path] = None) -> "Credentials":
        if yaml_path is None:
            yaml_path = os.environ.get("ASC_CREDENTIALS_PATH")
        if yaml_path and Path(yaml_path).exists():
            return cls.from_yaml(yaml_path)
        return cls.from_env()


class TokenManager:
    def __init__(self, credentials: Credentials):
        self.credentials = credentials
        self._token: Optional[str] = None
        self._expires_at: float = 0

    @property
    def token(self) -> str:
        now = time.time()
        if self._token is None or now >= self._expires_at:
            self._generate()
        return self._token

    def _generate(self):
        now = int(time.time())
        payload = {
            "iss": self.credentials.issuer_id,
            "iat": now,
            "exp": now + 20 * 60,
            "aud": "appstoreconnect-v1",
        }
        self._token = jwt.encode(
            payload,
            self.credentials.private_key,
            algorithm="ES256",
            headers={"kid": self.credentials.key_id},
        )
        self._expires_at = now + 19 * 60
