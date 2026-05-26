#!/usr/bin/env python3
"""Generate deterministic Lumina ReAct SFT and DPO data.

The generated records are intentionally compact enough for Lumina's 12K mobile
context budget while still exposing the standard ReAct schema, compressed tool
list, focused tool schemas, and representative observations.
"""

from __future__ import annotations

import json
import random
from dataclasses import dataclass
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
OUTPUT_DIR = ROOT / "TrainingData"
SFT_PATH = OUTPUT_DIR / "lumina_react_sft_300.jsonl"
SFT_RECORD_COUNT = 300
DPO_BASE_RECORD_COUNT = 500
DPO_HARD_NEGATIVE_COUNT = 100
DPO_RECORD_COUNT = DPO_BASE_RECORD_COUNT + DPO_HARD_NEGATIVE_COUNT
DPO_PATH = OUTPUT_DIR / f"lumina_react_dpo_{DPO_RECORD_COUNT}.jsonl"
MANIFEST_PATH = OUTPUT_DIR / "manifest.json"
SEED = 20260526
CONTEXT_BUDGET = 12_000


TOOLS: dict[str, dict[str, Any]] = {
    "ask_user": {"side": "read", "params": {"reason": "string", "questions": "array", "sensitivity": "string?", "timeoutSeconds": "number?"}, "desc": "Ask the user structured questions in Lumina UI and wait for answers."},
    "device.current_time": {"side": "read", "params": {}, "desc": "Read local device time and timezone."},
    "device.power_status": {"side": "read", "params": {}, "desc": "Read battery, charging, low power, and thermal state."},
    "network.status": {"side": "read", "params": {}, "desc": "Read connectivity, interface type, constrained and low-data state."},
    "storage.status": {"side": "read", "params": {}, "desc": "Read available storage and app data footprint."},
    "calendar.search": {"side": "read", "params": {"start": "iso8601?", "end": "iso8601?", "query": "string?"}, "desc": "Search calendar events."},
    "calendar.availability": {"side": "read", "params": {"start": "iso8601", "end": "iso8601"}, "desc": "Check calendar free/busy availability."},
    "calendar.create": {"side": "write", "params": {"title": "string", "start": "iso8601", "end": "iso8601", "notes": "string?"}, "desc": "Create a calendar event."},
    "calendar.update": {"side": "write", "params": {"eventID": "string?", "query": "string?", "title": "string?", "start": "iso8601?", "end": "iso8601?"}, "desc": "Update a calendar event."},
    "calendar.delete": {"side": "write", "params": {"eventID": "string?", "query": "string"}, "desc": "Delete a calendar event."},
    "reminder.search": {"side": "read", "params": {"query": "string?", "dueStart": "iso8601?", "dueEnd": "iso8601?", "includeCompleted": "bool?"}, "desc": "Search reminders."},
    "reminder.create": {"side": "write", "params": {"title": "string", "due": "iso8601?", "notes": "string?"}, "desc": "Create a reminder."},
    "reminder.update": {"side": "write", "params": {"reminderID": "string?", "query": "string?", "title": "string?", "due": "iso8601?"}, "desc": "Update a reminder."},
    "reminder.complete": {"side": "write", "params": {"reminderID": "string?", "query": "string"}, "desc": "Complete a reminder."},
    "reminder.delete": {"side": "write", "params": {"reminderID": "string?", "query": "string"}, "desc": "Delete a reminder."},
    "contacts.search": {"side": "read", "params": {"query": "string", "fields": "array?"}, "desc": "Search contacts with minimal fields."},
    "contacts.create": {"side": "write", "params": {"givenName": "string", "familyName": "string?", "phone": "string?", "email": "string?"}, "desc": "Create a contact."},
    "contacts.update": {"side": "write", "params": {"contactID": "string?", "query": "string?", "phone": "string?", "email": "string?"}, "desc": "Update a contact."},
    "contacts.open": {"side": "write", "params": {"contactID": "string?", "query": "string"}, "desc": "Open a contact card."},
    "message.compose": {"side": "write", "params": {"recipient": "string", "body": "string"}, "desc": "Open a message draft; never silently send."},
    "email.compose": {"side": "write", "params": {"to": "string", "subject": "string", "body": "string"}, "desc": "Open an email draft; never silently send."},
    "phone.call": {"side": "write", "params": {"recipient": "string", "service": "string?"}, "desc": "Open a phone or FaceTime entry; never silently call."},
    "maps.search": {"side": "write", "params": {"query": "string"}, "desc": "Open Apple Maps search."},
    "maps.route": {"side": "write", "params": {"destination": "string", "mode": "string?"}, "desc": "Open Apple Maps route."},
    "location.current": {"side": "read", "params": {"reverseGeocode": "bool?"}, "desc": "Read current location with permission."},
    "notification.schedule": {"side": "write", "params": {"title": "string", "body": "string?", "fireDate": "iso8601"}, "desc": "Schedule a local notification."},
    "clipboard.read": {"side": "read", "params": {"kind": "string?"}, "desc": "Read current clipboard text or URL."},
    "clipboard.write": {"side": "write", "params": {"text": "string"}, "desc": "Write text to clipboard."},
    "file.save_note": {"side": "write", "params": {"filename": "string", "content": "markdown"}, "desc": "Save a Markdown note in app documents."},
    "file.list_notes": {"side": "read", "params": {"query": "string?"}, "desc": "List app Markdown notes."},
    "file.read_note": {"side": "read", "params": {"filename": "string"}, "desc": "Read an app Markdown note."},
    "file.update_note": {"side": "write", "params": {"filename": "string", "append": "string?", "content": "markdown?"}, "desc": "Update an app Markdown note."},
    "file.delete_note": {"side": "write", "params": {"filename": "string"}, "desc": "Delete an app Markdown note."},
    "share.prepare": {"side": "write", "params": {"item": "string", "title": "string?"}, "desc": "Open a system share sheet."},
    "app.open_settings": {"side": "write", "params": {"section": "string?"}, "desc": "Open Lumina settings."},
    "ledger.record": {"side": "write", "params": {"amount": "number", "currency": "string?", "title": "string", "category": "string?"}, "desc": "Record local ledger transaction."},
    "ledger.search": {"side": "read", "params": {"query": "string?", "start": "iso8601?", "end": "iso8601?"}, "desc": "Search local ledger transactions."},
    "ledger.summary": {"side": "read", "params": {"query": "string?", "period": "string?"}, "desc": "Summarize local ledger transactions."},
    "ledger.update": {"side": "write", "params": {"transactionID": "string?", "query": "string?", "amount": "number?", "title": "string?"}, "desc": "Update local ledger transaction."},
    "ledger.delete": {"side": "write", "params": {"transactionID": "string?", "query": "string"}, "desc": "Delete local ledger transaction."},
    "subscription.add": {"side": "write", "params": {"url": "string", "title": "string?"}, "desc": "Add RSS or URL subscription."},
    "subscription.list": {"side": "read", "params": {"query": "string?"}, "desc": "List subscriptions."},
    "subscription.refresh": {"side": "write", "params": {"subscriptionID": "string?", "query": "string?"}, "desc": "Refresh a subscription."},
    "subscription.remove": {"side": "write", "params": {"subscriptionID": "string?", "query": "string"}, "desc": "Remove a subscription."},
    "webpage.fetch_text": {"side": "read", "params": {"url": "string"}, "desc": "Fetch webpage readable text."},
    "document.read_text": {"side": "read", "params": {"path": "string"}, "desc": "Read text from sandbox document."},
    "image.extract_text": {"side": "read", "params": {"attachmentID": "string?"}, "desc": "OCR an attached image."},
    "image.describe_metadata": {"side": "read", "params": {"attachmentID": "string?"}, "desc": "Read image dimensions, type, and size."},
    "calculator.evaluate": {"side": "read", "params": {"expression": "string"}, "desc": "Evaluate local calculation."},
    "text.transform": {"side": "read", "params": {"text": "string", "operation": "string"}, "desc": "Transform local text."},
    "url.open": {"side": "write", "params": {"url": "string"}, "desc": "Open URL after confirmation."},
    "memory.ingest_text": {"side": "write", "params": {"title": "string", "text": "string", "source": "string?", "sensitivity": "string?"}, "desc": "Persist user-approved durable memory."},
    "weather.current": {"side": "read", "params": {"latitude": "number?", "longitude": "number?", "locationName": "string?"}, "desc": "Read WeatherKit current weather on iOS when available."},
    "weather.forecast": {"side": "read", "params": {"latitude": "number?", "longitude": "number?", "locationName": "string?", "days": "number?"}, "desc": "Read WeatherKit forecast on iOS when available."},
    "health.summary": {"side": "read", "params": {"metrics": "array", "start": "iso8601?", "end": "iso8601?"}, "desc": "Read high-sensitivity HealthKit summary on iOS after permission."},
    "health.query_samples": {"side": "read", "params": {"metric": "string", "start": "iso8601", "end": "iso8601", "limit": "number?"}, "desc": "Read small high-sensitivity HealthKit sample summaries on iOS after permission."},
}


@dataclass(frozen=True)
class TaskTemplate:
    category: str
    instruction: str
    tools: tuple[str, ...]
    params: tuple[dict[str, Any], ...]
    observation: str
    final: str
    difficulty: str = "medium"
    memory_disabled: bool = True
    ask_user_disabled: bool = True


BASE_TASKS: list[TaskTemplate] = [
    TaskTemplate("time", "现在几点？", ("device.current_time",), ({},), "device.current_time succeeded summary=2026-05-26 09:30:00 Asia/Shanghai", "现在是 2026-05-26 09:30，时区 Asia/Shanghai。"),
    TaskTemplate("calendar", "帮我查今天下午有没有会议", ("calendar.search",), ({"start": "2026-05-26T12:00:00+08:00", "end": "2026-05-26T18:00:00+08:00"},), "calendar.search succeeded summary=找到 2 个日历事件", "今天下午有 2 个日历事件，我已经按时间整理好了。"),
    TaskTemplate("calendar_create", "帮我创建明天上午 7 点的日程：LuminaTest 去上厕所", ("device.current_time", "calendar.create"), ({}, {"title": "LuminaTest 去上厕所", "start": "2026-05-27T07:00:00+08:00", "end": "2026-05-27T07:30:00+08:00"}), "device.current_time succeeded summary=2026-05-26 09:30:00 Asia/Shanghai", "已创建明天上午 7:00 的日程：LuminaTest 去上厕所。"),
    TaskTemplate("calendar_update", "把 LuminaTest 明天 7 点的日程改成 7 点半", ("calendar.search", "calendar.update"), ({"query": "LuminaTest 明天 7 点"}, {"query": "LuminaTest 明天 7 点", "start": "2026-05-27T07:30:00+08:00", "end": "2026-05-27T08:00:00+08:00"}), "calendar.search succeeded summary=找到 1 个匹配日程", "已把 LuminaTest 日程改到明天 7:30。"),
    TaskTemplate("calendar_availability", "我明天下午三点到四点有空吗", ("calendar.availability",), ({"start": "2026-05-27T15:00:00+08:00", "end": "2026-05-27T16:00:00+08:00"},), "calendar.availability succeeded summary=该时间段空闲", "明天下午 3:00 到 4:00 看起来是空闲的。"),
    TaskTemplate("reminder_search", "查一下我今天还有哪些提醒", ("reminder.search",), ({"dueStart": "2026-05-26T00:00:00+08:00", "dueEnd": "2026-05-26T23:59:59+08:00", "includeCompleted": False},), "reminder.search succeeded summary=找到 3 个未完成提醒", "今天还有 3 个未完成提醒。"),
    TaskTemplate("reminder_create", "明天早上 8 点提醒我 LuminaTest 带伞", ("device.current_time", "reminder.create"), ({}, {"title": "LuminaTest 带伞", "due": "2026-05-27T08:00:00+08:00"}), "device.current_time succeeded summary=2026-05-26 09:30:00 Asia/Shanghai", "已创建明天早上 8:00 的提醒：LuminaTest 带伞。"),
    TaskTemplate("contacts", "找联系人 test 的电话", ("contacts.search",), ({"query": "test", "fields": ["phone"]},), "contacts.search succeeded summary=找到联系人 test，包含 1 个电话号码", "找到了 test 的电话号码。"),
    TaskTemplate("message", "帮我给 test 发短信：我十分钟后到", ("message.compose",), ({"recipient": "test", "body": "我十分钟后到"},), "message.compose succeeded summary=短信草稿已打开，等待用户手动发送", "短信草稿已准备好，需要你在系统短信界面手动发送。"),
    TaskTemplate("email", "给 test 写一封邮件草稿，主题是 LuminaTest 周报", ("email.compose",), ({"to": "test@example.com", "subject": "LuminaTest 周报", "body": "你好，这是 LuminaTest 周报草稿。"},), "email.compose succeeded summary=邮件草稿已打开", "邮件草稿已准备好，没有静默发送。"),
    TaskTemplate("maps", "在地图里搜附近咖啡店", ("maps.search",), ({"query": "附近咖啡店"},), "maps.search succeeded summary=已打开地图搜索", "已打开地图搜索附近咖啡店。"),
    TaskTemplate("location", "我现在在哪", ("location.current",), ({"reverseGeocode": True},), "location.current succeeded summary=已读取当前位置，精度 35 米", "已读取当前位置，精度约 35 米。"),
    TaskTemplate("notification", "半小时后通知我 LuminaTest 喝水", ("device.current_time", "notification.schedule"), ({}, {"title": "LuminaTest 喝水", "fireDate": "2026-05-26T10:00:00+08:00"}), "device.current_time succeeded summary=2026-05-26 09:30:00 Asia/Shanghai", "已安排 30 分钟后的本地通知：LuminaTest 喝水。"),
    TaskTemplate("clipboard_read", "读取剪贴板里的链接", ("clipboard.read",), ({"kind": "url"},), "clipboard.read succeeded summary=剪贴板包含 https://example.com", "剪贴板里有链接：https://example.com。"),
    TaskTemplate("clipboard_write", "把这段文字复制到剪贴板：LuminaTest benchmark", ("clipboard.write",), ({"text": "LuminaTest benchmark"},), "clipboard.write succeeded summary=已写入文本剪贴板", "已把文本写入剪贴板。"),
    TaskTemplate("file_save", "把 LuminaTest 会议纪要保存成 Markdown 笔记", ("file.save_note",), ({"filename": "LuminaTest-meeting.md", "content": "# LuminaTest 会议纪要\n\n- 待整理"},), "file.save_note succeeded summary=已保存 LuminaTest-meeting.md", "已保存 Markdown 笔记：LuminaTest-meeting.md。"),
    TaskTemplate("file_update", "给 LuminaTest-daily.md 追加今天的进展", ("file.update_note",), ({"filename": "LuminaTest-daily.md", "append": "\n- 今天完成本地 ReAct 测试"},), "file.update_note succeeded summary=已追加内容", "已追加今天的进展到 LuminaTest-daily.md。"),
    TaskTemplate("ledger", "记录 42 元 LuminaTest 咖啡支出", ("ledger.record",), ({"amount": 42, "currency": "CNY", "title": "LuminaTest 咖啡", "category": "coffee"},), "ledger.record succeeded summary=已记录 42 CNY", "已记录 42 元 LuminaTest 咖啡支出。"),
    TaskTemplate("ledger_summary", "汇总这个月 LuminaTest 咖啡花了多少钱", ("ledger.summary",), ({"query": "LuminaTest 咖啡", "period": "month"},), "ledger.summary succeeded summary=本月合计 82 CNY", "本月 LuminaTest 咖啡支出合计 82 元。"),
    TaskTemplate("subscription", "订阅 https://example.com/feed.xml，标题标记 LuminaTest", ("subscription.add",), ({"url": "https://example.com/feed.xml", "title": "LuminaTest"},), "subscription.add succeeded summary=已保存订阅源", "已订阅 LuminaTest feed。"),
    TaskTemplate("web", "抓取 https://example.com 的正文并整理成 3 条摘要", ("webpage.fetch_text", "text.transform"), ({"url": "https://example.com"}, {"text": "Example Domain content", "operation": "summarize_3_bullets"}), "webpage.fetch_text succeeded summary=抓取到 1256 字正文", "已抓取网页并整理成 3 条摘要。"),
    TaskTemplate("document", "读取 Documents 里的 LuminaTest-report.md", ("document.read_text",), ({"path": "LuminaTest-report.md"},), "document.read_text succeeded summary=读取到 680 字 Markdown", "已读取 LuminaTest-report.md。"),
    TaskTemplate("image_meta", "看看这张图片的尺寸和文件大小", ("image.describe_metadata",), ({"attachmentID": "latest"},), "image.describe_metadata succeeded summary=PNG 1170x2532 1.2 MB", "这张图片是 PNG，尺寸 1170x2532，约 1.2 MB。"),
    TaskTemplate("calculator", "计算 12*(8+3)-5", ("calculator.evaluate",), ({"expression": "12*(8+3)-5"},), "calculator.evaluate succeeded summary=127", "计算结果是 127。"),
    TaskTemplate("system", "查看当前设备电量、网络和可用存储，判断是否适合执行本地任务", ("device.power_status", "network.status", "storage.status"), ({}, {}, {}), "device.power_status succeeded summary=电量 82%，非低电量", "当前设备状态适合执行本地任务。"),
    TaskTemplate("memory_write", "记住：我偏好早上处理深度工作", ("memory.ingest_text",), ({"title": "工作偏好", "text": "用户偏好早上处理深度工作", "source": "user_explicit", "sensitivity": "normal"},), "memory.ingest_text succeeded summary=已保存 1 条长期记忆", "已记住：你偏好早上处理深度工作。", memory_disabled=False, ask_user_disabled=False),
    TaskTemplate("ask_user", "帮我安排一下明天的工作", ("ask_user",), ({"reason": "缺少明天工作安排偏好", "questions": [{"id": "priority", "question": "明天优先安排哪类工作？", "options": [{"label": "深度工作", "description": "优先留出连续时间"}, {"label": "会议沟通", "description": "优先处理协作事项"}]}], "sensitivity": "normal", "timeoutSeconds": 120},), "ask_user succeeded summary=用户选择：深度工作", "我已收到你的偏好：明天优先安排深度工作。", memory_disabled=False, ask_user_disabled=False),
    TaskTemplate("ask_user_message", "帮我给 test 发条消息", ("ask_user",), ({"reason": "缺少短信正文", "questions": [{"id": "message_body", "question": "你想发送什么内容？", "options": [{"label": "我晚点到", "description": "通知对方会迟到"}, {"label": "稍后联系", "description": "告诉对方稍后再说"}]}], "sensitivity": "normal", "timeoutSeconds": 120},), "ask_user succeeded summary=用户选择：我晚点到", "我已收到短信内容，下一步可以准备短信草稿。", memory_disabled=False, ask_user_disabled=False),
    TaskTemplate("weather_current", "看一下我现在这里的天气", ("location.current", "weather.current"), ({"reverseGeocode": True}, {"latitude": 31.2304, "longitude": 121.4737}), "location.current succeeded summary=当前位置：上海，精度 40 米", "当前位置天气已读取：晴，约 24°C。"),
    TaskTemplate("weather_forecast", "查一下明天上海会不会下雨，提醒我是否要带伞", ("weather.forecast", "text.transform"), ({"locationName": "上海", "days": 2}, {"text": "明天上海小雨概率 65%，气温 20-25°C", "operation": "weather_advice"}), "weather.forecast succeeded summary=明天有小雨概率 65%", "明天上海有较高降雨概率，建议带伞。"),
    TaskTemplate("health_summary", "帮我看一下今天步数和活动能量摘要", ("device.current_time", "health.summary"), ({}, {"metrics": ["steps", "activeEnergyBurned"], "start": "2026-05-26T00:00:00+08:00", "end": "2026-05-26T23:59:59+08:00"}), "device.current_time succeeded summary=2026-05-26 09:30:00 Asia/Shanghai", "今天健康摘要已读取：步数 3200，活动能量 180 kcal。"),
    TaskTemplate("health_samples", "读取今天最近几条心率样本摘要，不要保存到记忆", ("device.current_time", "health.query_samples"), ({}, {"metric": "heartRate", "start": "2026-05-26T00:00:00+08:00", "end": "2026-05-26T23:59:59+08:00", "limit": 5}), "health.query_samples succeeded summary=最近心率样本 5 条，范围 68-92 bpm", "最近心率样本范围约 68-92 bpm；我没有保存到记忆。"),
]


COMPLEX_TASKS: list[TaskTemplate] = [
    TaskTemplate("calendar_file", "先查明天上午 7:00 到 7:30 是否空闲；如果空闲，创建 LuminaTest 早起准备日程，并把结果保存成 Markdown 笔记。", ("calendar.availability", "calendar.create", "file.save_note"), ({"start": "2026-05-27T07:00:00+08:00", "end": "2026-05-27T07:30:00+08:00"}, {"title": "LuminaTest 早起准备", "start": "2026-05-27T07:00:00+08:00", "end": "2026-05-27T07:30:00+08:00"}, {"filename": "LuminaTest-morning.md", "content": "已创建早起准备日程。"}), "calendar.availability succeeded summary=空闲", "已创建日程并保存 Markdown 记录。", "hard"),
    TaskTemplate("reminder_notification", "创建明天 8 点的 LuminaTest 出门提醒，同时安排 7:50 的本地通知。", ("device.current_time", "reminder.create", "notification.schedule"), ({}, {"title": "LuminaTest 出门", "due": "2026-05-27T08:00:00+08:00"}, {"title": "LuminaTest 出门预备", "fireDate": "2026-05-27T07:50:00+08:00"}), "reminder.create succeeded summary=提醒已创建", "已分别创建系统提醒和本地通知。", "hard"),
    TaskTemplate("contact_message", "查找联系人 test；如果有电话，准备短信草稿：我会晚 10 分钟到。", ("contacts.search", "message.compose"), ({"query": "test", "fields": ["phone"]}, {"recipient": "test", "body": "我会晚 10 分钟到"}), "contacts.search succeeded summary=找到唯一电话号码", "短信草稿已准备好，需手动发送。", "medium"),
    TaskTemplate("context_note", "读取当前时间、电量、网络状态，把它们整理成 LuminaTest 本地运行记录并保存为 Markdown。", ("device.current_time", "device.power_status", "network.status", "file.save_note"), ({}, {}, {}, {"filename": "LuminaTest-run-context.md", "content": "# LuminaTest 本地运行记录\n\n- 时间：2026-05-26 09:30\n- 电量：82%\n- 网络：可用"}), "network.status succeeded summary=Wi-Fi 可用，非低数据模式", "已保存本地运行记录。", "hard"),
    TaskTemplate("web_save", "检查网络状态，如果可联网就抓取 https://example.com，提炼 3 个要点并保存为 LuminaTest-example-summary.md。", ("network.status", "webpage.fetch_text", "text.transform", "file.save_note"), ({}, {"url": "https://example.com"}, {"text": "Example Domain", "operation": "summarize_3_bullets"}, {"filename": "LuminaTest-example-summary.md", "content": "## 摘要\n- Example Domain 是示例站点。"}), "network.status succeeded summary=可联网", "已抓取网页并保存摘要。", "hard"),
    TaskTemplate("ledger_share", "查询本月 LuminaTest 支出摘要，把摘要保存为 Markdown，并准备分享面板。", ("ledger.summary", "file.save_note", "share.prepare"), ({"query": "LuminaTest", "period": "month"}, {"filename": "LuminaTest-ledger-summary.md", "content": "本月 LuminaTest 支出合计 82 元。"}, {"item": "LuminaTest-ledger-summary.md", "title": "LuminaTest 支出摘要"}), "ledger.summary succeeded summary=本月合计 82 CNY", "已保存支出摘要并准备分享。", "hard"),
    TaskTemplate("ask_user_then_calendar", "帮我安排明天下午的工作；如果缺少偏好，先问我想优先深度工作还是会议沟通。", ("ask_user", "calendar.availability", "calendar.create"), ({"reason": "需要安排偏好", "questions": [{"id": "work_mode", "question": "明天下午优先安排什么？", "options": [{"label": "深度工作", "description": "留出连续 2 小时"}, {"label": "会议沟通", "description": "安排沟通和同步"}]}], "sensitivity": "normal", "timeoutSeconds": 120}, {"start": "2026-05-27T14:00:00+08:00", "end": "2026-05-27T16:00:00+08:00"}, {"title": "LuminaTest 深度工作", "start": "2026-05-27T14:00:00+08:00", "end": "2026-05-27T16:00:00+08:00"}), "ask_user succeeded summary=用户选择：深度工作", "已按你的选择安排明天下午深度工作。", "hard", memory_disabled=False, ask_user_disabled=False),
    TaskTemplate("weather_calendar", "查看明天上海天气；如果上午有雨，就创建 8 点带伞提醒，否则只给出天气建议。", ("weather.forecast", "reminder.create"), ({"locationName": "上海", "days": 2}, {"title": "LuminaTest 带伞", "due": "2026-05-27T08:00:00+08:00"}), "weather.forecast succeeded summary=明天上午小雨概率 70%", "明天上午可能下雨，已创建 8 点带伞提醒。", "hard"),
    TaskTemplate("health_weather_plan", "结合今天步数摘要和明早天气，给出一个不超过 3 条的轻量出行建议，不要保存健康数据。", ("health.summary", "weather.forecast", "text.transform"), ({"metrics": ["steps", "walkingRunningDistance"], "start": "2026-05-26T00:00:00+08:00", "end": "2026-05-26T23:59:59+08:00"}, {"locationName": "上海", "days": 2}, {"text": "步数 3200；明早小雨", "operation": "health_weather_advice"}), "health.summary succeeded summary=步数 3200，步行距离 2.4 km", "建议明早带伞，安排轻量步行，并避免把健康数据保存到记忆。", "hard"),
]


def compact_tool_list() -> str:
    return "; ".join(sorted(TOOLS))


def focused_schema(tool_names: tuple[str, ...]) -> str:
    rendered = []
    for name in tool_names:
        schema = TOOLS[name]
        params = ", ".join(f"{key}:{value}" for key, value in schema["params"].items()) or "{}"
        side = "w" if schema["side"] == "write" else "r"
        rendered.append(f"{name}|{side}|{{{params}}}|{schema['desc']}")
    return "; ".join(rendered)


def system_prompt(task: TaskTemplate, *, eval_mode: bool = True) -> str:
    contract = (
        'Return exactly one JSON object. Valid shapes: '
        '{"type":"tool_use","thought":"...","tool_name":"tool.name","parameters":{},"requires_confirmation":false} '
        'or {"type":"final_answer","thought":"...","content":"markdown"}. '
        'Never output observation, tool_call, function, arguments, input, action, markdown fences, or prose.'
    )
    policies = [
        "You are Lumina, a local-first Apple-platform assistant. Complete tasks through ReAct tools.",
        "Relative time requires device.current_time before writing dated events.",
        "Side-effect tools require requires_confirmation=true.",
        "Never claim success before an observation confirms the tool result.",
        "Never silently send messages, emails, or calls; compose/open only.",
    ]
    if task.memory_disabled:
        policies.append("Memory tools are disabled for this run; do not read or write memory.")
    else:
        policies.append("Durable memory may be saved only when the user explicitly asks or a stable reusable preference appears.")
    if task.ask_user_disabled:
        policies.append("ask_user is disabled; do not ask follow-up questions.")
    else:
        policies.append("ask_user is available; use it only when required information is missing and no safe default exists.")
    if any(tool.startswith("weather.") for tool in task.tools):
        policies.append("Weather tools are iOS-only WeatherKit capabilities; if unavailable, return a clear final_answer instead of fabricating weather.")
    if any(tool.startswith("health.") for tool in task.tools):
        policies.append("Health tools expose high-sensitivity HealthKit data; request only minimal metrics and never save health data to memory unless explicitly requested.")
    prompt = "\n".join([contract, *policies])
    return f"{prompt}\nTools(all): {compact_tool_list()}\nToolSchemas(focused): {focused_schema(task.tools)}\nBudget: context={CONTEXT_BUDGET}, maxObservationChars=900"


def user_context(task: TaskTemplate, observation: str | None = None) -> str:
    obs = "none" if observation is None else observation
    return f"User: {task.instruction}\nObs: {obs}\nReturn next ReAct JSON."


def tool_response(tool_name: str, params: dict[str, Any], thought: str | None = None) -> str:
    requires = TOOLS[tool_name]["side"] == "write"
    payload = {
        "type": "tool_use",
        "thought": thought or f"Need {tool_name} to make progress.",
        "tool_name": tool_name,
        "parameters": params,
        "requires_confirmation": requires,
    }
    return json.dumps(payload, ensure_ascii=False, separators=(",", ":"))


def final_response(content: str) -> str:
    return json.dumps(
        {"type": "final_answer", "thought": "The runtime observation is sufficient to answer.", "content": content},
        ensure_ascii=False,
        separators=(",", ":"),
    )


def bad_response(task: TaskTemplate, variant: int) -> tuple[str, str]:
    first_tool = task.tools[0]
    first_params = task.params[0]
    variants = [
        ("openai_tool_call", {"type": "tool_call", "function": first_tool, "arguments": first_params}),
        ("tool_name_as_type", {"type": first_tool, "input": first_params}),
        ("fake_success_final", {"type": "final_answer", "thought": "done", "content": "已完成。"}),
        ("observation_from_model", {"type": "observation", "tool_name": first_tool, "content": "succeeded"}),
        ("wrong_tool", {"type": "tool_use", "thought": "Use a nearby tool.", "tool_name": wrong_tool_for(first_tool), "parameters": {}, "requires_confirmation": False}),
        ("ask_user_when_disabled", {"type": "tool_use", "thought": "Ask the user.", "tool_name": "ask_user", "parameters": {"questions": []}, "requires_confirmation": False}),
        ("memory_when_disabled", {"type": "tool_use", "thought": "Search memory.", "tool_name": "local.search", "parameters": {"query": task.instruction}, "requires_confirmation": False}),
        ("prose_not_json", f"我会调用 {first_tool} 来完成这个任务。"),
    ]
    reason, bad = variants[variant % len(variants)]
    if isinstance(bad, str):
        return reason, bad
    return reason, json.dumps(bad, ensure_ascii=False, separators=(",", ":"))


def hard_negative_response(task: TaskTemplate, variant: int) -> tuple[str, str]:
    write_tools = [tool for tool in task.tools if TOOLS[tool]["side"] == "write"]
    target_tool = write_tools[0] if write_tools else task.tools[0]
    target_index = task.tools.index(target_tool)
    target_params = task.params[target_index]
    variants = [
        (
            "missing_confirmation_for_side_effect",
            {
                "type": "tool_use",
                "thought": "This action changes user data, but the confirmation flag is omitted.",
                "tool_name": target_tool,
                "parameters": target_params,
                "requires_confirmation": False,
            },
        ),
        (
            "premature_success_without_observation",
            {
                "type": "final_answer",
                "thought": "Assume the operation succeeded.",
                "content": "已完成并写入系统。",
            },
        ),
        (
            "fabricated_sensitive_data",
            {
                "type": "final_answer",
                "thought": "Invent private data instead of using a permitted tool.",
                "content": "我已经查到了详细联系人、健康和位置数据。",
            },
        ),
        (
            "unregistered_tool_name",
            {
                "type": "tool_use",
                "thought": "Use an unavailable native API directly.",
                "tool_name": "system.private_database.read",
                "parameters": {"query": task.instruction},
                "requires_confirmation": False,
            },
        ),
        (
            "non_standard_react_schema",
            {
                "thought": "Use a tool.",
                "action": target_tool,
                "action_input": target_params,
            },
        ),
        (
            "disabled_ask_user",
            {
                "type": "tool_use",
                "thought": "Ask follow-up even though this run disabled ask_user.",
                "tool_name": "ask_user",
                "parameters": {"reason": "Need more info", "questions": []},
                "requires_confirmation": False,
            },
        ),
        (
            "disabled_memory_access",
            {
                "type": "tool_use",
                "thought": "Read memory even though this run disabled memory access.",
                "tool_name": "local.search",
                "parameters": {"query": task.instruction},
                "requires_confirmation": False,
            },
        ),
        (
            "silent_external_completion",
            {
                "type": "final_answer",
                "thought": "Claim an external communication was sent.",
                "content": "短信、邮件或电话已经自动完成。",
            },
        ),
        (
            "raw_json_user_visible_final",
            {
                "type": "final_answer",
                "thought": "Expose internal data instead of a user-readable answer.",
                "content": json.dumps({"tool": target_tool, "parameters": target_params}, ensure_ascii=False),
            },
        ),
        (
            "health_memory_leak",
            {
                "type": "tool_use",
                "thought": "Persist high-sensitivity health data without explicit request.",
                "tool_name": "memory.ingest_text",
                "parameters": {
                    "title": "健康摘要",
                    "text": "保存用户健康样本和位置上下文。",
                    "source": "auto",
                    "sensitivity": "privateData",
                },
                "requires_confirmation": False,
            },
        ),
    ]
    reason, bad = variants[variant % len(variants)]
    if reason == "missing_confirmation_for_side_effect" and not write_tools:
        reason, bad = variants[1]
    if reason == "disabled_ask_user" and not task.ask_user_disabled:
        reason, bad = variants[3]
    if reason == "disabled_memory_access" and not task.memory_disabled:
        reason, bad = variants[4]
    return reason, json.dumps(bad, ensure_ascii=False, separators=(",", ":"))


def wrong_tool_for(tool: str) -> str:
    if tool.startswith("calendar."):
        return "reminder.search"
    if tool.startswith("reminder."):
        return "calendar.search"
    if tool.startswith("ledger."):
        return "subscription.list"
    if tool.startswith("contacts."):
        return "calendar.search"
    if tool.startswith("file."):
        return "clipboard.read"
    return "device.current_time" if tool != "device.current_time" else "calendar.search"


def make_sft_records() -> list[dict[str, Any]]:
    rng = random.Random(SEED)
    tasks = BASE_TASKS + COMPLEX_TASKS
    records: list[dict[str, Any]] = []
    for index in range(SFT_RECORD_COUNT):
        task = tasks[index % len(tasks)]
        mode = index % 3
        if mode == 0:
            step = 0
            assistant = tool_response(task.tools[step], task.params[step], "Need the first required runtime fact or action.")
            observation = None
        elif mode == 1 and len(task.tools) > 1:
            step = 1
            assistant = tool_response(task.tools[step], task.params[step], "Use the previous observation to continue.")
            observation = task.observation
        else:
            assistant = final_response(task.final)
            observation = task.observation
        tools = list(task.tools)
        rng.shuffle(tools)
        record = {
            "id": f"sft-{index + 1:03d}",
            "format": "chat-sft-react-v1",
            "contextBudgetTokens": CONTEXT_BUDGET,
            "metadata": {
                "category": task.category,
                "difficulty": task.difficulty,
                "expectedTools": list(task.tools),
                "memoryAccessDisabled": task.memory_disabled,
                "askUserDisabled": task.ask_user_disabled,
            },
            "messages": [
                {"role": "system", "content": system_prompt(task)},
                {"role": "user", "content": user_context(task, observation)},
                {"role": "assistant", "content": assistant},
            ],
        }
        records.append(record)
    return records


def make_dpo_records() -> list[dict[str, Any]]:
    tasks = BASE_TASKS + COMPLEX_TASKS
    records: list[dict[str, Any]] = []
    for index in range(DPO_BASE_RECORD_COUNT):
        task = tasks[(index * 7) % len(tasks)]
        after_observation = index % 4 == 0
        if after_observation:
            prompt_obs = task.observation
            chosen = final_response(task.final)
        else:
            prompt_obs = None
            chosen = tool_response(task.tools[0], task.params[0], "Choose the next valid tool; do not invent results.")
        reason, rejected = bad_response(task, index)
        records.append(
            {
                "id": f"dpo-{index + 1:03d}",
                "format": "chat-dpo-react-v1",
                "contextBudgetTokens": CONTEXT_BUDGET,
                "metadata": {
                    "category": task.category,
                    "difficulty": task.difficulty,
                    "expectedTools": list(task.tools),
                    "memoryAccessDisabled": task.memory_disabled,
                    "askUserDisabled": task.ask_user_disabled,
                    "rejectionReason": reason,
                },
                "prompt": [
                    {"role": "system", "content": system_prompt(task)},
                    {"role": "user", "content": user_context(task, prompt_obs)},
                ],
                "chosen": {"role": "assistant", "content": chosen},
                "rejected": {"role": "assistant", "content": rejected},
            }
        )
    for index in range(DPO_HARD_NEGATIVE_COUNT):
        task = tasks[(index * 11 + 5) % len(tasks)]
        after_observation = index % 5 == 0
        if after_observation:
            prompt_obs = task.observation
            chosen = final_response(task.final)
        else:
            prompt_obs = None
            chosen = tool_response(task.tools[0], task.params[0], "Choose the next valid ReAct step and obey tool policy.")
        reason, rejected = hard_negative_response(task, index)
        records.append(
            {
                "id": f"dpo-hard-negative-{index + 1:03d}",
                "format": "chat-dpo-react-v1",
                "contextBudgetTokens": CONTEXT_BUDGET,
                "metadata": {
                    "category": task.category,
                    "difficulty": task.difficulty,
                    "expectedTools": list(task.tools),
                    "memoryAccessDisabled": task.memory_disabled,
                    "askUserDisabled": task.ask_user_disabled,
                    "rejectionReason": reason,
                    "negativeAugmentation": True,
                    "negativeAugmentationRatio": DPO_HARD_NEGATIVE_COUNT / DPO_BASE_RECORD_COUNT,
                },
                "prompt": [
                    {"role": "system", "content": system_prompt(task)},
                    {"role": "user", "content": user_context(task, prompt_obs)},
                ],
                "chosen": {"role": "assistant", "content": chosen},
                "rejected": {"role": "assistant", "content": rejected},
            }
        )
    return records


def write_jsonl(path: Path, records: list[dict[str, Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as handle:
        for record in records:
            handle.write(json.dumps(record, ensure_ascii=False, separators=(",", ":")) + "\n")


def validate_jsonl(path: Path, expected: int) -> None:
    count = 0
    max_chars = 0
    with path.open(encoding="utf-8") as handle:
        for line in handle:
            count += 1
            max_chars = max(max_chars, len(line))
            json.loads(line)
    if count != expected:
        raise RuntimeError(f"{path} has {count} records, expected {expected}")
    if max_chars > 18_000:
        raise RuntimeError(f"{path} has an unexpectedly long record: {max_chars} chars")


def main() -> None:
    sft = make_sft_records()
    dpo = make_dpo_records()
    write_jsonl(SFT_PATH, sft)
    write_jsonl(DPO_PATH, dpo)
    validate_jsonl(SFT_PATH, SFT_RECORD_COUNT)
    validate_jsonl(DPO_PATH, DPO_RECORD_COUNT)
    manifest = {
        "schemaVersion": "lumina-training-data-v1",
        "generatedBy": "scripts/generate_training_data.py",
        "seed": SEED,
        "contextBudgetTokens": CONTEXT_BUDGET,
        "sft": {"path": str(SFT_PATH.relative_to(ROOT)), "records": len(sft)},
        "dpo": {
            "path": str(DPO_PATH.relative_to(ROOT)),
            "records": len(dpo),
            "baseRecords": DPO_BASE_RECORD_COUNT,
            "hardNegativeRecords": DPO_HARD_NEGATIVE_COUNT,
            "hardNegativeRatio": DPO_HARD_NEGATIVE_COUNT / DPO_BASE_RECORD_COUNT,
        },
        "notes": [
            "All assistant targets use standard Lumina ReAct JSON.",
            "DPO records contain paired rejected responses; 20% hard-negative augmentation is included for policy and schema failures.",
            "Most samples disable memory and ask_user to match evaluation runs; a smaller subset covers ask_user flow.",
            "WeatherKit and HealthKit samples are included for iOS-only and high-sensitivity permission behavior.",
        ],
    }
    MANIFEST_PATH.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(manifest, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
