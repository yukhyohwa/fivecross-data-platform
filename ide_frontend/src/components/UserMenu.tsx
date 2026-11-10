import React, { useState, useEffect } from 'react';
import { api, clearUserCache } from '../services/api';
import { ChangePasswordDialog } from './ChangePasswordDialog';
import { LLMConfigDialog } from './LLMConfig/LLMConfigDialog';
import { Bot, Key, LogOut, ChevronDown, Settings } from 'lucide-react';
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from './ui/dropdown-menu';

export const UserMenu: React.FC = () => {
  const [username, setUsername] = useState('');
  const [identityName, setIdentityName] = useState('');
  const [permissions, setPermissions] = useState<string[]>([]);
  const [showChangePwd, setShowChangePwd] = useState(false);
  const [showLLM, setShowLLM] = useState(false);

  useEffect(() => {
    try {
      const stored = JSON.parse(localStorage.getItem('wb_jwt_user') || '');
      if (stored?.username) setUsername(stored.username);
      if (stored?.identity_name) setIdentityName(stored.identity_name);
      if (stored?.permissions) setPermissions(stored.permissions);
    } catch {}
    api.getMe().then((u) => {
      const names = Array.isArray(u.identity_name) ? u.identity_name.join('、') : (u.identity_name || '');
      setUsername(u.username);
      setIdentityName(names);
      setPermissions(u.permissions || []);
      localStorage.setItem('wb_jwt_user', JSON.stringify({ id: u.id, username: u.username, identity_name: names, permissions: u.permissions || [] }));
    }).catch(() => {});
  }, []);

  const hasSystem = permissions.includes('system');

  const handleLogout = async () => {
    await api.logout().catch(() => {});
    clearUserCache();
    window.location.reload();
  };

  return (
    <>
      <DropdownMenu>
        <DropdownMenuTrigger asChild>
          {/* 审计 P2-12：触发器补 aria-label（含可见用户名，满足 Label in Name），读屏可辨识为「用户菜单」 */}
          <button aria-label={`用户菜单：${username || '用户'}`} className="flex items-center gap-1.5 rounded border border-border bg-transparent px-2 py-1 text-xs text-foreground hover:bg-accent transition-colors cursor-pointer">
            {/* 审计 P2-12：装饰性状态点对读屏隐藏 */}
            <span aria-hidden="true" className="inline-block h-1.5 w-1.5 rounded-full bg-green-500" />
            {username || '用户'}
            {identityName && <span className="text-muted-foreground text-[10px]">{identityName}</span>}
            {hasSystem && <Settings className="h-3 w-3 text-sql-accent" />}
            <ChevronDown className="h-3 w-3 text-muted-foreground" />
          </button>
        </DropdownMenuTrigger>
        <DropdownMenuContent align="end" className="min-w-[150px]">
          <DropdownMenuItem onClick={() => setShowLLM(true)}>
            <Bot className="h-3.5 w-3.5" />
            LLM配置
          </DropdownMenuItem>
          <DropdownMenuItem onClick={() => setShowChangePwd(true)}>
            <Key className="h-3.5 w-3.5" />
            修改密码
          </DropdownMenuItem>
          <DropdownMenuSeparator />
          <DropdownMenuItem onClick={handleLogout} className="text-destructive focus:text-destructive">
            <LogOut className="h-3.5 w-3.5" />
            退出登录
          </DropdownMenuItem>
        </DropdownMenuContent>
      </DropdownMenu>

      {showChangePwd && <ChangePasswordDialog onClose={() => setShowChangePwd(false)} />}
      {showLLM && <LLMConfigDialog onClose={() => setShowLLM(false)} />}
    </>
  );
};
