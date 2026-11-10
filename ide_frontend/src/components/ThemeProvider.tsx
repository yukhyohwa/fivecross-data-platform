import React, { useState, useEffect, createContext, useContext } from 'react';

type Theme = 'dark' | 'light';
const STORAGE_KEY = 'sql-ide-theme';

const ThemeCtx = createContext<{ theme: Theme; toggle: () => void }>({ theme: 'dark', toggle: () => {} });

export const useTheme = () => useContext(ThemeCtx);

export const ThemeProvider: React.FC<{ children: React.ReactNode }> = ({ children }) => {
  const [theme, setTheme] = useState<Theme>(() => {
    return (localStorage.getItem(STORAGE_KEY) as Theme) || 'dark';
  });

  useEffect(() => {
    localStorage.setItem(STORAGE_KEY, theme);
    // Use class-based dark mode (Tailwind dark: variant)
    if (theme === 'dark') {
      document.documentElement.classList.add('dark');
    } else {
      document.documentElement.classList.remove('dark');
    }
  }, [theme]);

  const toggle = () => setTheme((t) => (t === 'dark' ? 'light' : 'dark'));

  return <ThemeCtx.Provider value={{ theme, toggle }}>{children}</ThemeCtx.Provider>;
};
