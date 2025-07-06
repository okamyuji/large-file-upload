import http from 'k6/http';
import { check, sleep } from 'k6';
import { Rate } from 'k6/metrics';

// カスタムメトリクス
const errorRate = new Rate('errors');

// テスト設定
export const options = {
  stages: [
    { duration: '2m', target: 10 }, // 2分で10ユーザーまで増加
    { duration: '5m', target: 10 }, // 5分間10ユーザーを維持
    { duration: '2m', target: 20 }, // 2分で20ユーザーまで増加
    { duration: '5m', target: 20 }, // 5分間20ユーザーを維持
    { duration: '2m', target: 0 },  // 2分で0ユーザーまで減少
  ],
  thresholds: {
    http_req_duration: ['p(95)<2000'], // 95%のリクエストが2秒以内
    http_req_failed: ['rate<0.1'],     // エラー率10%未満
    errors: ['rate<0.1'],              // カスタムエラー率10%未満
  },
};

// 環境変数
const BASE_URL = __ENV.TARGET_URL || 'http://localhost:8080';

// テストデータ生成
function generateTestData(size) {
  const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
  let result = '';
  for (let i = 0; i < size; i++) {
    result += chars.charAt(Math.floor(Math.random() * chars.length));
  }
  return result;
}

// SHA256ハッシュ計算（簡易版）
function simpleHash(data) {
  // 実際のSHA256の代わりに簡易ハッシュを使用
  let hash = 0;
  for (let i = 0; i < data.length; i++) {
    const char = data.charCodeAt(i);
    hash = ((hash << 5) - hash) + char;
    hash = hash & hash; // 32bit整数に変換
  }
  return Math.abs(hash).toString(16);
}

// メインテスト関数
export default function () {
  // ヘルスチェック
  healthCheck();
  
  // 小さなファイルのアップロードテスト
  smallFileUploadTest();
  
  // 中程度のファイルのアップロードテスト
  mediumFileUploadTest();
  
  // 大きなファイルのアップロードテスト（チャンク分割）
  largeFileUploadTest();
  
  sleep(1);
}

function healthCheck() {
  const response = http.get(`${BASE_URL}/health`);
  check(response, {
    'health check status is 200': (r) => r.status === 200,
    'health check response time < 500ms': (r) => r.timings.duration < 500,
  }) || errorRate.add(1);
}

function smallFileUploadTest() {
  const testData = generateTestData(1024); // 1KB
  const fileChecksum = simpleHash(testData);
  
  // セッション作成
  const sessionPayload = {
    fileName: 'small-test.txt',
    totalChunks: 1,
    fileSize: testData.length,
    fileChecksum: fileChecksum,
    chunkSize: 1024
  };
  
  const sessionResponse = http.post(
    `${BASE_URL}/upload/session`,
    JSON.stringify(sessionPayload),
    {
      headers: { 'Content-Type': 'application/json' },
      tags: { name: 'create_session_small' }
    }
  );
  
  check(sessionResponse, {
    'small file session created': (r) => r.status === 201,
  }) || errorRate.add(1);
  
  if (sessionResponse.status === 201) {
    const session = JSON.parse(sessionResponse.body);
    
    // チャンクアップロード
    uploadChunk(session.sessionId, 0, testData, 'small');
    
    // アップロード完了
    completeUpload(session.sessionId, 'small');
  }
}

function mediumFileUploadTest() {
  const chunkSize = 64 * 1024; // 64KB
  const totalSize = 512 * 1024; // 512KB
  const totalChunks = Math.ceil(totalSize / chunkSize);
  
  const fileChecksum = simpleHash('medium-test-file');
  
  // セッション作成
  const sessionPayload = {
    fileName: 'medium-test.txt',
    totalChunks: totalChunks,
    fileSize: totalSize,
    fileChecksum: fileChecksum,
    chunkSize: chunkSize
  };
  
  const sessionResponse = http.post(
    `${BASE_URL}/upload/session`,
    JSON.stringify(sessionPayload),
    {
      headers: { 'Content-Type': 'application/json' },
      tags: { name: 'create_session_medium' }
    }
  );
  
  check(sessionResponse, {
    'medium file session created': (r) => r.status === 201,
  }) || errorRate.add(1);
  
  if (sessionResponse.status === 201) {
    const session = JSON.parse(sessionResponse.body);
    
    // 複数チャンクのアップロード
    for (let i = 0; i < totalChunks; i++) {
      const chunkData = generateTestData(chunkSize);
      uploadChunk(session.sessionId, i, chunkData, 'medium');
    }
    
    // ステータス確認
    checkStatus(session.sessionId, 'medium');
    
    // アップロード完了
    completeUpload(session.sessionId, 'medium');
  }
}

function largeFileUploadTest() {
  const chunkSize = 1024 * 1024; // 1MB
  const totalSize = 10 * 1024 * 1024; // 10MB
  const totalChunks = Math.ceil(totalSize / chunkSize);
  
  const fileChecksum = simpleHash('large-test-file');
  
  // セッション作成
  const sessionPayload = {
    fileName: 'large-test.txt',
    totalChunks: totalChunks,
    fileSize: totalSize,
    fileChecksum: fileChecksum,
    chunkSize: chunkSize
  };
  
  const sessionResponse = http.post(
    `${BASE_URL}/upload/session`,
    JSON.stringify(sessionPayload),
    {
      headers: { 'Content-Type': 'application/json' },
      tags: { name: 'create_session_large' }
    }
  );
  
  check(sessionResponse, {
    'large file session created': (r) => r.status === 201,
  }) || errorRate.add(1);
  
  if (sessionResponse.status === 201) {
    const session = JSON.parse(sessionResponse.body);
    
    // 並列でいくつかのチャンクをアップロード（実際のクライアントの動作を模擬）
    const chunksToUpload = Math.min(3, totalChunks); // 最大3チャンクを並列アップロード
    
    for (let i = 0; i < chunksToUpload; i++) {
      const chunkData = generateTestData(chunkSize);
      uploadChunk(session.sessionId, i, chunkData, 'large');
    }
    
    // ステータス確認
    checkStatus(session.sessionId, 'large');
  }
}

function uploadChunk(sessionId, chunkIndex, chunkData, testType) {
  const chunkChecksum = simpleHash(chunkData);
  
  const response = http.put(
    `${BASE_URL}/upload/session/${sessionId}/chunk/${chunkIndex}`,
    chunkData,
    {
      headers: {
        'Content-Type': 'application/octet-stream',
        'X-Chunk-Checksum': chunkChecksum
      },
      tags: { name: `upload_chunk_${testType}` }
    }
  );
  
  check(response, {
    [`${testType} chunk upload success`]: (r) => r.status === 200,
    [`${testType} chunk upload time < 5s`]: (r) => r.timings.duration < 5000,
  }) || errorRate.add(1);
}

function checkStatus(sessionId, testType) {
  const response = http.get(
    `${BASE_URL}/upload/session/${sessionId}/status`,
    {
      tags: { name: `check_status_${testType}` }
    }
  );
  
  check(response, {
    [`${testType} status check success`]: (r) => r.status === 200,
    [`${testType} status check time < 1s`]: (r) => r.timings.duration < 1000,
  }) || errorRate.add(1);
}

function completeUpload(sessionId, testType) {
  const response = http.post(
    `${BASE_URL}/upload/session/${sessionId}/complete`,
    '',
    {
      tags: { name: `complete_upload_${testType}` }
    }
  );
  
  check(response, {
    [`${testType} upload complete success`]: (r) => r.status === 200,
    [`${testType} upload complete time < 3s`]: (r) => r.timings.duration < 3000,
  }) || errorRate.add(1);
}

// テスト終了時の処理
export function teardown(data) {
  console.log('Performance test completed');
}
