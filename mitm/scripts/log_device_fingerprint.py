from __future__ import annotations

import json
import os
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path
from typing import Dict, List, Set, Tuple, Union

from mitmproxy import ctx, http


# 需要重点监控的设备指纹 / 遥测关键字。
KEYWORDS: List[str] = [
    "machineId",
    "deviceId",
    "hostname",
    "networkInterfaces",
    "stable_id",
    "userID",
    "fingerprint",
    "telemetry",
    "statsig",
    "anonymousId",
    "organizationUUID",
    "accountUUID",
    "user_metadata",
    "event_metadata",
]

# 这些请求头可能直接携带敏感认证信息，写入报告前必须脱敏。
SENSITIVE_HEADERS = {
    "authorization",
    "cookie",
    "proxy-authorization",
    "x-api-key",
}

# 为了避免日志过大，仅保留有限长度的请求体预览。
MAX_BODY_PREVIEW = 16 * 1024


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


class DeviceFingerprintLogger:
    def __init__(self) -> None:
        # 报告目录优先由启动器注入；若未注入，则退回当前目录，方便独立调试。
        report_dir = os.environ.get("CAC_MITM_REPORT_DIR", os.getcwd())
        self.report_dir = Path(report_dir).expanduser()
        self.report_dir.mkdir(parents=True, exist_ok=True)

        self.hits_path = self.report_dir / "device_hits.jsonl"
        self.summary_path = Path(
            os.environ.get(
                "CAC_MITM_SUMMARY_PATH",
                str(self.report_dir / "summary.json"),
            )
        ).expanduser()
        self.summary_path.parent.mkdir(parents=True, exist_ok=True)

        self.started_at = utc_now()
        self.total_requests = 0
        self.total_hits = 0
        self.first_hit_at = None
        self.last_hit_at = None
        self.keyword_counts: Counter[str] = Counter()
        self.source_counts: Counter[str] = Counter()
        self.host_counts: Counter[str] = Counter()
        self.method_counts: Counter[str] = Counter()
        self.path_counts: Counter[str] = Counter()

    def load(self, loader) -> None:
        ctx.log.info(f"[cac-mitm] 报告目录：{self.report_dir}")
        ctx.log.info(f"[cac-mitm] 命中日志：{self.hits_path}")
        self._write_summary(final=False)

    def request(self, flow: http.HTTPFlow) -> None:
        self.total_requests += 1

        request = flow.request
        matched_keywords, matched_sources = self._find_matches(request)
        if not matched_keywords:
            return

        timestamp = utc_now()
        if self.first_hit_at is None:
            self.first_hit_at = timestamp
        self.last_hit_at = timestamp

        self.total_hits += 1
        self.host_counts[request.pretty_host or request.host] += 1
        self.method_counts[request.method] += 1
        self.path_counts[request.path] += 1
        for keyword in matched_keywords:
            self.keyword_counts[keyword] += 1
        for source in matched_sources:
            self.source_counts[source] += 1

        record = {
            "timestamp": timestamp,
            "request": {
                "id": flow.id,
                "method": request.method,
                "scheme": request.scheme,
                "host": request.pretty_host or request.host,
                "port": request.port,
                "path": request.path,
                "url": request.pretty_url,
                "http_version": request.http_version,
                "headers": self._sanitize_headers(request.headers),
                "query": self._query_dict(request),
                "content_length": len(request.raw_content or b""),
                "content_type": request.headers.get("content-type", ""),
                "body_preview": self._body_preview(request),
            },
            "match": {
                "keywords": matched_keywords,
                "sources": matched_sources,
            },
            "client": {
                "peername": list(getattr(flow.client_conn, "peername", None) or []),
                "sockname": list(getattr(flow.client_conn, "sockname", None) or []),
            },
        }

        self._append_jsonl(record)
        self._write_summary(final=False)

    def done(self) -> None:
        # mitmproxy 退出时再次落盘，确保 summary.json 处于最终状态。
        self._write_summary(final=True)
        ctx.log.info(f"[cac-mitm] 汇总文件已写入：{self.summary_path}")

    def _find_matches(self, request: http.Request) -> Tuple[List[str], List[str]]:
        matched_keywords: Set[str] = set()
        matched_sources: Set[str] = set()

        url_blob = request.pretty_url.lower()
        query_blob = json.dumps(self._query_dict(request), ensure_ascii=False).lower()
        header_blob = json.dumps(
            self._headers_for_matching(request.headers), ensure_ascii=False
        ).lower()
        body_blob = self._safe_body_text(request).lower()

        for keyword in KEYWORDS:
            needle = keyword.lower()
            if needle in url_blob:
                matched_keywords.add(keyword)
                matched_sources.add("url")
            if needle in query_blob:
                matched_keywords.add(keyword)
                matched_sources.add("query")
            if needle in header_blob:
                matched_keywords.add(keyword)
                matched_sources.add("headers")
            if needle in body_blob:
                matched_keywords.add(keyword)
                matched_sources.add("body")

        return sorted(matched_keywords), sorted(matched_sources)

    def _query_dict(self, request: http.Request) -> Dict[str, Union[List[str], str]]:
        query: Dict[str, Union[List[str], str]] = {}
        for key, value in request.query.items(multi=True):
            if key in query:
                current = query[key]
                if isinstance(current, list):
                    current.append(value)
                else:
                    query[key] = [current, value]
            else:
                query[key] = value
        return query

    def _headers_for_matching(self, headers) -> Dict[str, Union[List[str], str]]:
        result: Dict[str, Union[List[str], str]] = {}
        for name, value in headers.items(multi=True):
            key = name.lower()
            if key in result:
                current = result[key]
                if isinstance(current, list):
                    current.append(value)
                else:
                    result[key] = [current, value]
            else:
                result[key] = value
        return result

    def _sanitize_headers(self, headers) -> Dict[str, Union[List[str], str]]:
        sanitized: Dict[str, Union[List[str], str]] = {}
        for name, value in headers.items(multi=True):
            safe_value = "[REDACTED]" if name.lower() in SENSITIVE_HEADERS else value
            if name in sanitized:
                current = sanitized[name]
                if isinstance(current, list):
                    current.append(safe_value)
                else:
                    sanitized[name] = [current, safe_value]
            else:
                sanitized[name] = safe_value
        return sanitized

    def _safe_body_text(self, request: http.Request) -> str:
        try:
            text = request.get_text(strict=False)
            return text or ""
        except Exception:
            raw = request.raw_content or b""
            return raw.decode("utf-8", errors="replace")

    def _body_preview(self, request: http.Request) -> str:
        body = self._safe_body_text(request)
        if len(body) <= MAX_BODY_PREVIEW:
            return body
        return body[:MAX_BODY_PREVIEW] + "\n...<truncated>"

    def _append_jsonl(self, payload: dict) -> None:
        with self.hits_path.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(payload, ensure_ascii=False) + "\n")

    def _write_summary(self, final: bool) -> None:
        summary = {
            "started_at": self.started_at,
            "finished_at": utc_now() if final else None,
            "report_dir": str(self.report_dir),
            "hits_file": str(self.hits_path),
            "total_requests_seen": self.total_requests,
            "total_hits": self.total_hits,
            "first_hit_at": self.first_hit_at,
            "last_hit_at": self.last_hit_at,
            "keyword_counts": dict(self.keyword_counts.most_common()),
            "source_counts": dict(self.source_counts.most_common()),
            "host_counts": dict(self.host_counts.most_common()),
            "method_counts": dict(self.method_counts.most_common()),
            "path_counts": dict(self.path_counts.most_common(20)),
        }

        temp_path = self.summary_path.with_suffix(self.summary_path.suffix + ".tmp")
        with temp_path.open("w", encoding="utf-8") as handle:
            json.dump(summary, handle, ensure_ascii=False, indent=2)
        temp_path.replace(self.summary_path)


addons = [DeviceFingerprintLogger()]
