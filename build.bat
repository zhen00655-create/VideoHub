@echo off
REM ============================================================
REM  影视仓 (VideoHub) 命令行构建脚本
REM  解决手动构建报 "00303168 SDK component missing"：
REM  必须显式设置 DEVECO_SDK_HOME / OHOS_BASE_SDK_HOME 指向 SDK 根目录。
REM  用法:
REM    build.bat                  (等同 assembleHap)
REM    build.bat clean            (清理)
REM    build.bat clean assembleHap(全量重编)
REM  注意: 若报构建目录锁冲突，先关闭 DevEco Studio。
REM ============================================================
setlocal

set "STUDIO=D:\Program Files\Huawei\DevEco Studio"
set "DEVECO_SDK_HOME=%STUDIO%\sdk"
set "OHOS_BASE_SDK_HOME=%STUDIO%\sdk"

set "HDC_HOME=%DEVECO_SDK_HOME%\hms\toolchains"
if exist "%HDC_HOME%" set "PATH=%HDC_HOME%;%PATH%"

set "NODE=%STUDIO%\tools\node\node.exe"
set "HVIGOR=%STUDIO%\tools\hvigor\bin\hvigorw.js"

if not exist "%NODE%" (
  echo [ERROR] 找不到 DevEco Studio node: %NODE%
  exit /b 1
)
if not exist "%HVIGOR%" (
  echo [ERROR] 找不到 hvigorw.js: %HVIGOR%
  exit /b 1
)

set "TASKS=%*"
if "%TASKS%"=="" set "TASKS=assembleHap"

echo [INFO] DEVECO_SDK_HOME=%DEVECO_SDK_HOME%
echo [INFO] 执行: %NODE% %HVIGOR% -p product=default %TASKS% --no-daemon
"%NODE%" "%HVIGOR%" -p product=default %TASKS% --no-daemon
endlocal
