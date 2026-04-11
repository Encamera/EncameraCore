"""Base HTTP client for App Store Connect API."""

from typing import Any, Optional

import requests

from asc.auth import Credentials, TokenManager


class ASCClient:
    BASE_URL = "https://api.appstoreconnect.apple.com"

    def __init__(self, credentials: Credentials):
        self.credentials = credentials
        self._token_manager = TokenManager(credentials)
        self._session = requests.Session()

    def _headers(self) -> dict[str, str]:
        return {
            "Authorization": f"Bearer {self._token_manager.token}",
            "Content-Type": "application/json",
        }

    def get(self, path: str, params: Optional[dict] = None) -> dict[str, Any]:
        url = f"{self.BASE_URL}{path}"
        resp = self._session.get(url, headers=self._headers(), params=params)
        resp.raise_for_status()
        return resp.json()

    def get_all(self, path: str, params: Optional[dict] = None) -> list[dict[str, Any]]:
        results = []
        url = f"{self.BASE_URL}{path}"
        while url:
            resp = self._session.get(url, headers=self._headers(), params=params)
            resp.raise_for_status()
            data = resp.json()
            results.extend(data.get("data", []))
            url = data.get("links", {}).get("next")
            params = None  # params are embedded in next URL
        return results

    def get_all_paginated_with_includes(
        self, path: str, params: Optional[dict] = None
    ) -> dict[str, list[dict[str, Any]]]:
        """Paginate through all pages, accumulating both data and included resources."""
        all_data: list[dict[str, Any]] = []
        all_included: list[dict[str, Any]] = []
        seen_included: set[str] = set()
        url = f"{self.BASE_URL}{path}"
        while url:
            resp = self._session.get(url, headers=self._headers(), params=params)
            resp.raise_for_status()
            body = resp.json()
            all_data.extend(body.get("data", []))
            for inc in body.get("included", []):
                key = f"{inc['type']}:{inc['id']}"
                if key not in seen_included:
                    seen_included.add(key)
                    all_included.append(inc)
            url = body.get("links", {}).get("next")
            params = None
        return {"data": all_data, "included": all_included}

    def post(self, path: str, data: dict[str, Any]) -> dict[str, Any]:
        url = f"{self.BASE_URL}{path}"
        resp = self._session.post(url, headers=self._headers(), json=data)
        if not resp.ok:
            try:
                error_body = resp.json()
            except Exception:
                error_body = resp.text
            raise RuntimeError(f"{resp.status_code} {resp.reason} for {url}: {error_body}")
        if resp.status_code == 204:
            return {}
        return resp.json()

    def patch(self, path: str, data: dict[str, Any]) -> dict[str, Any]:
        url = f"{self.BASE_URL}{path}"
        resp = self._session.patch(url, headers=self._headers(), json=data)
        if not resp.ok:
            try:
                error_body = resp.json()
            except Exception:
                error_body = resp.text
            raise RuntimeError(f"{resp.status_code} {resp.reason} for {url}: {error_body}")
        return resp.json()

    def delete(self, path: str) -> None:
        url = f"{self.BASE_URL}{path}"
        resp = self._session.delete(url, headers=self._headers())
        resp.raise_for_status()

    def find_app_by_bundle_id(self, bundle_id: str) -> dict[str, Any]:
        data = self.get("/v1/apps", params={"filter[bundleId]": bundle_id})
        apps = data.get("data", [])
        if not apps:
            raise ValueError(f"No app found with bundle ID: {bundle_id}")
        return apps[0]

    def resolve_app_id(self) -> str:
        if self.credentials.app_id:
            return self.credentials.app_id
        if self.credentials.bundle_id:
            app = self.find_app_by_bundle_id(self.credentials.bundle_id)
            return app["id"]
        raise ValueError("No app_id or bundle_id configured")
