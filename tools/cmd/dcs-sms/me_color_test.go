package main

import "testing"

func TestParseDrawingColorToHex(t *testing.T) {
	tests := []struct {
		in      string
		alpha   uint8
		want    string
		wantErr bool
	}{
		{"", 0xFF, "", false},
		{"red", 0xFF, "'0xff0000ff'", false},
		{"#ff8000", 0xFF, "'0xff8000ff'", false},
		{"#ff8000aa", 0xFF, "'0xff8000aa'", false},
		{"FF8000", 0xFF, "'0xff8000ff'", false},
		{"0x000000aa", 0xFF, "'0x000000aa'", false},
		{"0X000000aa", 0xFF, "'0x000000aa'", false},
		{"0xff8000", 0xFF, "'0xff8000ff'", false},
		{"#nothex", 0xFF, "", true},
		{"toolong0xff8000aa", 0xFF, "", true},
	}
	for _, tt := range tests {
		got, err := parseDrawingColorToHex(tt.in, tt.alpha)
		if tt.wantErr {
			if err == nil {
				t.Errorf("parseDrawingColorToHex(%q): want error, got %q", tt.in, got)
			}
			continue
		}
		if err != nil {
			t.Errorf("parseDrawingColorToHex(%q): unexpected error: %v", tt.in, err)
			continue
		}
		if got != tt.want {
			t.Errorf("parseDrawingColorToHex(%q) = %q, want %q", tt.in, got, tt.want)
		}
	}
}

func TestParseColorToLua_AcceptsHexPrefixes(t *testing.T) {
	cases := []string{"#ff0000", "0xff0000", "0Xff0000", "ff0000"}
	for _, in := range cases {
		got, err := parseColorToLua(in)
		if err != nil {
			t.Errorf("parseColorToLua(%q): unexpected error: %v", in, err)
			continue
		}
		if got == "" {
			t.Errorf("parseColorToLua(%q): empty result", in)
		}
	}
}
