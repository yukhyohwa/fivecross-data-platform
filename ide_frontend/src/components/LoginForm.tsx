import React, { useState } from 'react';
import { setToken, api, scopeWorkspaceToUser, scopeSessionToUser } from '../services/api';
import { useStore } from '../stores/useStore';
import { Database, Loader2 } from 'lucide-react';
import { Button } from './ui/button';
import { Input } from './ui/input';
import { Card, CardContent, CardHeader } from './ui/card';

// 审计 P1-17：内部后台，无公开注册——账号由管理员在「系统管理 → 用户管理」内部开通
export const LoginForm: React.FC<{ onLogin: () => void }> = ({ onLogin }) => {
  const [username, setUsername] = useState('');
  const [password, setPassword] = useState('');
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState('');

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!username.trim() || !password) return;
    setLoading(true);
    setError('');
    try {
      const resp = await api.login(username.trim(), password);
      setToken(resp.access_token);
      // 账号切换保护：与持久化工作区（sql-ide-storage）归属不一致时，清空上一账号的编辑器页签/结果“历史”
      if (resp.user?.id && resp.user.id !== 'anonymous') {
        // 顺序不可换：先 scope（比对/清 localStorage 旧 key），再 setUserKey 对齐内存态，最后 reset 写回干净态。
        // 若先 setUserKey，localStorage 已被盖新章，scope 比对恒一致、脏数据不再被清
        const changed = scopeWorkspaceToUser(resp.user.id);
        scopeSessionToUser(resp.user.id); // sessionStorage AI 对话按 stamp 清空（每标签页独立）
        useStore.getState().setUserKey(resp.user.id);
        if (changed) useStore.getState().resetUserWorkspace();
      }
      onLogin();
    } catch (e: any) {
      setError(e.message || '操作失败');
    } finally {
      setLoading(false);
    }
  };

  return (
    <div className="min-h-screen flex items-center justify-center bg-background">
      {/* 审计 P2-12：登录卡片固定宽改 min()，窄屏不横向溢出 */}
      <Card className="w-[min(380px,94vw)] shadow-xl">
        <CardHeader className="items-center pb-2 pt-8">
          <div className="flex flex-col items-center gap-2">
            <div className="rounded-xl bg-primary/10 p-3">
              <Database className="h-7 w-7 text-primary" />
            </div>
            <h1 className="text-xl font-bold tracking-tight">FiveCross 数据平台</h1>
            <p className="text-sm text-muted-foreground">多用户数据库管理工具</p>
          </div>
        </CardHeader>

        <CardContent className="pb-8">
          <form onSubmit={handleSubmit} className="flex flex-col gap-4">
            <div className="flex flex-col gap-1.5">
              <label className="text-xs font-medium text-muted-foreground">用户名</label>
              {/* 审计 P2-12：输入框补 aria-label（可见 label 未与控件程序化关联） */}
              <Input
                value={username}
                onChange={(e) => setUsername(e.target.value)}
                placeholder="输入用户名"
                aria-label="用户名"
                autoFocus
                disabled={loading}
              />
            </div>

            <div className="flex flex-col gap-1.5">
              <label className="text-xs font-medium text-muted-foreground">密码</label>
              <Input
                type="password"
                value={password}
                onChange={(e) => setPassword(e.target.value)}
                placeholder="输入密码"
                aria-label="密码"
                disabled={loading}
              />
            </div>

            {error && (
              <div className="rounded-md bg-destructive/10 border border-destructive/20 px-3 py-2 text-sm text-destructive">
                {error}
              </div>
            )}

            <Button type="submit" disabled={loading} className="w-full mt-1">
              {loading && <Loader2 className="mr-1 h-4 w-4 animate-spin" />}
              登 录
            </Button>
          </form>

          <div className="mt-4 rounded-md bg-muted px-3 py-2 text-xs text-muted-foreground leading-relaxed">
            初始账号为公司邮箱姓名前缀，默认密码 123456，登录后请尽快修改密码。如没有权限，请联系数据分析师
          </div>
        </CardContent>
      </Card>
    </div>
  );
};
