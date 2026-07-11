package utils

import (
	"path/filepath"
	"testing"
)

func TestSafeSessionFilePath(t *testing.T) {
	tests := []struct {
		name      string
		sessionID string
		fileName  string
		wantPath  string
		wantErr   bool
	}{
		{
			name:      "正常なセッションID",
			sessionID: "session_1783791593_af687fee633b6e81",
			fileName:  "chunk_0.dat",
			wantPath:  filepath.Join("uploads", "session_1783791593_af687fee633b6e81", "chunk_0.dat"),
		},
		{
			name:      "ハイフンを含むIDも許可",
			sessionID: "sess-abc_123",
			fileName:  "chunk_1.lock",
			wantPath:  filepath.Join("uploads", "sess-abc_123", "chunk_1.lock"),
		},
		{
			name:      "パストラバーサルを拒否",
			sessionID: "../etc",
			fileName:  "passwd",
			wantErr:   true,
		},
		{
			name:      "パス区切りを含むIDを拒否",
			sessionID: "a/b",
			fileName:  "chunk_0.dat",
			wantErr:   true,
		},
		{
			name:      "空のセッションIDを拒否",
			sessionID: "",
			fileName:  "chunk_0.dat",
			wantErr:   true,
		},
		{
			name:      "ドットのみのIDを拒否",
			sessionID: "..",
			fileName:  "chunk_0.dat",
			wantErr:   true,
		},
		{
			name:      "129文字以上のIDを拒否",
			sessionID: string(make([]byte, 129)),
			fileName:  "chunk_0.dat",
			wantErr:   true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := SafeSessionFilePath(tt.sessionID, tt.fileName)
			if tt.wantErr {
				if err == nil {
					t.Fatalf("エラーを期待したが nil (got=%q)", got)
				}
				return
			}
			if err != nil {
				t.Fatalf("予期しないエラー: %v", err)
			}
			if got != tt.wantPath {
				t.Fatalf("path = %q, want %q", got, tt.wantPath)
			}
		})
	}
}
