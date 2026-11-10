export interface ConnectionConfig {
  id: string;
  name: string;
  host: string;
  port: number;
  user: string;
  password?: string;
  database: string;
  charset?: string;
  db_type?: string;
  use_ssh?: boolean;
  ssh_host?: string;
  ssh_port?: number;
  ssh_user?: string;
  ssh_password?: string;
  ssh_key_path?: string;
}

export interface QueryResultData {
  type: 'select' | 'dml';
  columns?: string[];
  rows?: Record<string, unknown>[];
  row_count?: number;
  affected_rows?: number;
  last_insert_id?: number | null;
  execution_time?: number;
}

export interface ExecuteQueryResponse {
  success: boolean;
  results: QueryResultData[];
  error?: string;
}

export interface HistoryItem {
  id: string;
  connection_name: string;
  sql: string;
  executed_at: string;
  duration: number;
  row_count: number;
}
