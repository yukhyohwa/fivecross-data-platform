from pydantic import BaseModel
from typing import Optional, List


class ConnectionConfig(BaseModel):
    name: str
    host: str
    port: int = 3306
    user: str
    password: str
    database: str
    db_type: str = "mysql"
    charset: str = "utf8mb4"
    use_ssh: bool = False
    ssh_host: Optional[str] = None
    ssh_port: int = 22
    ssh_user: Optional[str] = None
    ssh_password: Optional[str] = None
    ssh_key_path: Optional[str] = None


class ConnectionTestResult(BaseModel):
    success: bool
    message: str


class ExecuteQueryRequest(BaseModel):
    connection_id: str
    sql: str
    max_rows: int = 0


class QueryResult(BaseModel):
    type: str  # 'select' | 'dml'
    columns: Optional[list[str]] = None
    rows: Optional[list[dict]] = None
    row_count: Optional[int] = None
    affected_rows: Optional[int] = None
    last_insert_id: Optional[int] = None
    execution_time: Optional[float] = None


class ExecuteQueryResponse(BaseModel):
    success: bool
    results: list[QueryResult] = []
    error: Optional[str] = None
    connection_lost: bool = False
    connection_id: Optional[str] = None


class HistoryItem(BaseModel):
    id: str
    connection_name: str
    sql: str
    executed_at: str
    duration: float
    row_count: int


# ── Auth Models ──

class UserBase(BaseModel):
    id: str
    username: str


class UserDetail(UserBase):
    role: str = "user"
    is_active: bool = True
    login_attempts: int = 0
    last_login_at: Optional[str] = None
    created_at: Optional[str] = None


class AuthResponse(BaseModel):
    user: UserBase
    access_token: str
    refresh_token: str
    expires_at: str


class TokenRefreshResponse(BaseModel):
    access_token: str
    refresh_token: str
    expires_at: str


class MeResponse(BaseModel):
    id: str
    username: str
    role: str
    last_login_at: Optional[str] = None


# ── Indicator Models ──

class IndicatorCreate(BaseModel):
    metric_name: str
    metric_alias: str = ""
    canonical_sql: str
    sql_fragments: list[dict] = []
    db_type: str = "mysql"
    description: str = ""
    domain: str = ""
    category: str = ""
    tags: list[str] = []
    owner: str = ""
    definition: str = ""
    aggregation_type: str = ""
    granularity: str = ""
    status: str = "draft"
    change_comment: str = ""


class IndicatorUpdate(BaseModel):
    metric_name: Optional[str] = None
    metric_alias: Optional[str] = None
    canonical_sql: Optional[str] = None
    sql_fragments: Optional[list[dict]] = None
    db_type: Optional[str] = None
    description: Optional[str] = None
    domain: Optional[str] = None
    category: Optional[str] = None
    tags: Optional[list[str]] = None
    owner: Optional[str] = None
    definition: Optional[str] = None
    aggregation_type: Optional[str] = None
    granularity: Optional[str] = None
    status: Optional[str] = None
    event_source: Optional[list[dict]] = None
    join_logic: Optional[list[dict]] = None
    filter_conditions: Optional[list[dict]] = None
    supported_filters: Optional[list[dict]] = None
    business_scenarios: Optional[list[str]] = None
    input_tables: Optional[list[dict]] = None
    test_cases: Optional[list[dict]] = None
    common_mistakes: Optional[list[dict]] = None
    known_edge_cases: Optional[list[dict]] = None
    change_comment: str = ""


class IndicatorResponse(BaseModel):
    id: int
    metric_id: str
    metric_name: str
    metric_alias: str = ""
    version: int = 1
    owner: str = ""
    status: str = "draft"
    domain: str = ""
    category: str = ""
    tags: list = []
    definition: str = ""
    aggregation_type: str = ""
    granularity: str = ""
    canonical_sql: str
    sql_fragments: list = []
    db_type: str = "mysql"
    sql_template_params: list = []
    event_source: list = []
    join_logic: list = []
    filter_conditions: list = []
    supported_filters: list = []
    business_scenarios: list = []
    input_tables: list = []
    test_cases: list = []
    common_mistakes: list = []
    known_edge_cases: list = []
    related_indicators: list = []
    change_log: list = []
    uncertain_fields: list = []
    created_at: str = ""
    updated_at: str = ""


class IndicatorFolderCreate(BaseModel):
    name: str
    parent_id: Optional[int] = None


class IndicatorMigrateResult(BaseModel):
    migrated: int = 0
    failed: int = 0
    errors: list[dict] = []


# ── Import/Export ──

class ImportRequest(BaseModel):
    items: list[dict]


class ImportResult(BaseModel):
    created: int = 0
    errors: list[dict] = []
    total: int = 0
