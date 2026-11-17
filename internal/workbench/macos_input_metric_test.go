package workbench

import "testing"

func TestMacOSInputMetricCountsDragWithoutContents(t *testing.T) {
	cases := []struct {
		request        macOSWindowRequest
		response, want string
	}{
		{macOSWindowRequest{Action: "pointer", Phase: "down", Text: "private"}, `{}`, "pointer-down"},
		{macOSWindowRequest{Action: "pointer", Phase: "move", Buttons: 1}, `{}`, "pointer-move-held"},
		{macOSWindowRequest{Action: "pointer", Phase: "up"}, `{"error":"window_changed"}`, "pointer-up-error"},
		{macOSWindowRequest{Action: "browser-pointer", Phase: "move"}, `{}`, "browser-pointer-move"},
	}
	for _, c := range cases {
		if got := macOSInputMetric(c.request, []byte(c.response)); got != c.want {
			t.Errorf("got %q, want %q", got, c.want)
		}
	}
}
