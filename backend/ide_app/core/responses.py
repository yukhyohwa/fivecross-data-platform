"""Unified HTTP response helpers.

Use `ok(data)` for success and `err(code, message)` for business-logic errors.
Raise HTTPException for HTTP-level errors (auth, not-found).
"""
from fastapi.responses import JSONResponse


def ok(data=None, message: str = "success") -> dict:
    return {"code": 0, "message": message, "data": data}


def err(code: int, message: str) -> JSONResponse:
    return JSONResponse(
        status_code=200,
        content={"code": code, "message": message, "data": None},
    )
