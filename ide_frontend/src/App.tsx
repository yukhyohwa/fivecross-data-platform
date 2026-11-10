import React, { useState, useEffect } from 'react';
import { Layout } from './components/Layout';
import { LoginForm } from './components/LoginForm';
import { ToastProvider } from './components/Toast';
import { api, getStoredToken, clearUserCache, scopeWorkspaceToUser, scopeSessionToUser } from './services/api';
import { useStore } from './stores/useStore';

const App: React.FC = () => {
  const [loggedIn, setLoggedIn] = useState(false);
  const [checking, setChecking] = useState(true);

  useEffect(() => {
    const token = getStoredToken();
    if (!token) {
      setChecking(false);
      return;
    }
    api.getMe().then((user) => {
      localStorage.setItem('wb_jwt_user', JSON.stringify({ id: user.id, username: user.username, role: user.role }));
      // 账号切换保护：持久化工作区（sql-ide-storage）归属校验，跨账号时清空上一账号的编辑器页签/结果“历史”
      if (user.id && user.id !== 'anonymous') {
        // 顺序不可换：先 scope（比对/清 localStorage 旧 key），再 setUserKey 对齐内存态，最后 reset 写回干净态。
        // 若先 setUserKey，localStorage 已被盖新章，scope 比对恒一致、脏数据不再被清
        const changed = scopeWorkspaceToUser(user.id);
        scopeSessionToUser(user.id); // sessionStorage AI 对话按 stamp 清空（每标签页独立）
        useStore.getState().setUserKey(user.id);
        if (changed) useStore.getState().resetUserWorkspace();
      }
      setLoggedIn(true);
    }).catch(() => {
      clearUserCache();
      setLoggedIn(false);
    }).finally(() => {
      setChecking(false);
    });
  }, []);

  if (checking) {
    return (
      <div style={{ height: '100vh', display: 'flex', alignItems: 'center', justifyContent: 'center', backgroundColor: '#111', color: '#666', fontSize: 14 }}>
        验证登录状态...
      </div>
    );
  }

  if (!loggedIn) {
    return (
      <ToastProvider>
        <LoginForm onLogin={() => { setLoggedIn(true); }} />
      </ToastProvider>
    );
  }

  return (
    <ToastProvider>
      <Layout />
    </ToastProvider>
  );
};

export default App;
