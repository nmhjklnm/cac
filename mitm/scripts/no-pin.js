// 仅用于 mitm 调试场景：当启动器显式注入时，绕过 Node TLS 证书校验。
// 注意：这个脚本不会自行启用，只有在 CAC_BYPASS_PINNING=1 时才会被 claude-mitm.sh 注入。

'use strict';

if (process.env.CAC_BYPASS_PINNING === '1') {
  const tls = require('tls');

  // 保留原始实现，便于后续排查或调试。
  const originalCheckServerIdentity = tls.checkServerIdentity;

  // 覆盖证书主机名校验逻辑，让 Node 在 MITM 调试场景中继续握手。
  tls.checkServerIdentity = function checkServerIdentityBypass() {
    return undefined;
  };

  // 暴露原始实现，方便在需要时由外部调试脚本读取。
  global.__CAC_ORIGINAL_TLS_CHECK_SERVER_IDENTITY__ = originalCheckServerIdentity;
}
