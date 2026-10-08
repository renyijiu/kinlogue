package ui

import (
	"testing"
	"time"

	"github.com/egoist/mygo/internal/platform"
)

// These regressions exercise the same event queue and bound value as real
// inputs; they do not require a particular system input method to be installed.
func regressionInput(t *testing.T, multiline bool, value *string) (*Tester, *editor) {
	t.Helper()
	var ed *editor
	tt := NewTester(func(c *Context) {
		var e *Element
		if multiline {
			e = TextArea(c, value).Size(300, 100)
		} else {
			e = TextInput(c, value).Size(300, 40)
		}
		e.Label("synthetic input")
		ed = e.st.editor
	}, 340, 150)
	tt.Click("synthetic input")
	return tt, ed
}

func TestCompositionCancelPreservesSelection(t *testing.T) {
	for _, multiline := range []bool{false, true} {
		name := "input"
		if multiline {
			name = "area"
		}
		t.Run(name, func(t *testing.T) {
			value := "前旧文后"
			tt, ed := regressionInput(t, multiline, &value)
			ed.anchor, ed.caret = 3, 1 // Retain the direction of the selection.
			tt.Frame()
			tt.Compose("xin", 3)
			tt.Compose("新", 1)
			if value != "前旧文后" {
				t.Errorf("candidate changed the committed value to %q", value)
			}
			if ime := tt.h.ime; ime.Text != "前旧文后" || ime.Start != 1 || ime.End != 3 {
				t.Errorf("candidate changed input method context: %+v", ime)
			}
			tt.Compose("", 0)
			if value != "前旧文后" || ed.anchor != 3 || ed.caret != 1 {
				t.Fatalf("cancel: value %q, anchor/caret %d/%d", value, ed.anchor, ed.caret)
			}
			if len(ed.undo) != 0 || len(ed.redo) != 0 {
				t.Fatal("cancel recorded an edit")
			}
			tt.Command("copy")
			if tt.Clipboard() != "旧文" {
				t.Fatalf("cancel lost the selected text: %q", tt.Clipboard())
			}
		})
	}
}

func TestCompositionCommitIsOneUndo(t *testing.T) {
	for _, sequence := range []string{"commit", "unmark-commit", "replacement-commit"} {
		t.Run(sequence, func(t *testing.T) {
			value := "前旧文后"
			tt, ed := regressionInput(t, true, &value)
			ed.anchor, ed.caret = 1, 3
			tt.Frame()
			tt.Compose("xin", 3)
			tt.Compose("新文", 2)
			if sequence != "commit" {
				// The macOS bridge emits an empty composition before insertion.
				tt.Compose("", 0)
			}
			if sequence == "replacement-commit" {
				tt.send(platform.SurfaceEvent{Kind: platform.TextInput, Text: "新文", Replace: true, From: 1, To: 3})
			} else {
				tt.Type("新文")
			}
			if value != "前新文后" {
				t.Fatalf("commit: %q", value)
			}
			tt.Command("undo")
			if value != "前旧文后" || ed.anchor != 1 || ed.caret != 3 {
				t.Fatalf("undo: value %q, anchor/caret %d/%d", value, ed.anchor, ed.caret)
			}
			tt.Command("redo")
			if value != "前新文后" || ed.anchor != 3 || ed.caret != 3 {
				t.Fatalf("redo: value %q, anchor/caret %d/%d", value, ed.anchor, ed.caret)
			}
		})
	}
}

func TestTypingOverSelectionIsOneUndo(t *testing.T) {
	value := "original"
	tt, ed := regressionInput(t, false, &value)
	tt.Command("selectAll")
	for _, s := range []string{"n", "e", "w"} {
		tt.Type(s)
	}
	tt.Command("undo")
	if value != "original" || ed.anchor != 0 || ed.caret != 8 {
		t.Fatalf("undo: value %q, anchor/caret %d/%d", value, ed.anchor, ed.caret)
	}
	tt.Command("redo")
	if value != "new" {
		t.Fatalf("redo: %q", value)
	}
}

func TestPasteRemainsSeparateFromTyping(t *testing.T) {
	for _, pasted := range []string{"x", "粘贴"} {
		t.Run(pasted, func(t *testing.T) {
			value := "seed"
			tt, _ := regressionInput(t, false, &value)
			tt.Key(0, KeyEnd)
			tt.Type("a")
			tt.SetClipboard(pasted)
			tt.Command("paste")
			tt.Type("b")
			for _, want := range []string{"seeda" + pasted, "seeda", "seed"} {
				tt.Command("undo")
				if value != want {
					t.Fatalf("undo: %q, want %q", value, want)
				}
			}
			for range 3 {
				tt.Command("redo")
			}
			if value != "seeda"+pasted+"b" {
				t.Fatalf("redo: %q", value)
			}
		})
	}
}

func TestTypingPauseAndCaretMovementEndUndoGroup(t *testing.T) {
	value := "seed"
	tt, ed := regressionInput(t, false, &value)
	tt.Command("selectAll")
	tt.Type("a")
	ed.lastEdit = time.Now().Add(-2 * time.Second)
	tt.Type("b")
	tt.Key(0, KeyLeft)
	tt.Type("c")
	for _, want := range []string{"ab", "a", "seed"} {
		tt.Command("undo")
		if value != want {
			t.Fatalf("undo: %q, want %q", value, want)
		}
	}
}

func TestCompositionAcrossParagraphs(t *testing.T) {
	value := "前\n旧文\n后"
	tt, ed := regressionInput(t, true, &value)
	ed.anchor, ed.caret = 1, 5
	tt.Frame()
	tt.Compose("xin", 3)
	if ed.displayText() != "前xin后" || value != "前\n旧文\n后" {
		t.Fatalf("candidate: display %q, value %q", ed.displayText(), value)
	}
	tt.Compose("", 0)
	if value != "前\n旧文\n后" || ed.buf.s != value || len(ed.buf.paras) != 3 {
		t.Fatalf("cancel: value %q, buffer %q, paragraphs %d", value, ed.buf.s, len(ed.buf.paras))
	}
	tt.Compose("xin", 3)
	tt.Type("新")
	tt.Command("undo")
	if value != "前\n旧文\n后" || ed.anchor != 1 || ed.caret != 5 {
		t.Fatalf("undo: value %q, anchor/caret %d/%d", value, ed.anchor, ed.caret)
	}
}

func TestCompositionEndsWithoutPublishingCandidate(t *testing.T) {
	for _, finish := range []string{"focus", "read-only", "app-value"} {
		t.Run(finish, func(t *testing.T) {
			value, other, readOnly := "原文", "", false
			var ed *editor
			tt := NewTester(func(c *Context) {
				Column(c).Children(func() {
					e := TextInput(c, &value).Size(200, 40).Label("first").ReadOnly(readOnly)
					ed = e.st.editor
					TextInput(c, &other).Size(200, 40).Label("second")
				})
			}, 300, 150)
			tt.Click("first")
			tt.Command("selectAll")
			tt.Compose("xin", 3)
			want := "原文"
			switch finish {
			case "focus":
				tt.Click("second")
			case "read-only":
				readOnly = true
				tt.Frame()
			case "app-value":
				want, value = "外部值", "外部值"
				tt.Frame()
			}
			if value != want || ed.buf.s != want || ed.compose != "" || ed.composeBefore != nil {
				t.Fatalf("%s left value %q, buffer %q, compose %q", finish, value, ed.buf.s, ed.compose)
			}
		})
	}
}

func TestCompositionCancelPreservesRedo(t *testing.T) {
	value := "原文"
	tt, _ := regressionInput(t, false, &value)
	tt.Command("selectAll")
	tt.Type("新文")
	tt.Command("undo")
	tt.Compose("xin", 3)
	tt.Compose("", 0)
	tt.Command("redo")
	if value != "新文" {
		t.Fatalf("cancel lost redo: %q", value)
	}
}

func TestReplacingSelectionStartsNewTypingGroup(t *testing.T) {
	value := "seed"
	tt, _ := regressionInput(t, false, &value)
	tt.Key(0, KeyEnd)
	tt.Type("a")
	tt.Command("selectAll")
	tt.Type("n")
	tt.Type("e")
	tt.Type("w")
	for _, want := range []string{"seeda", "seed"} {
		tt.Command("undo")
		if value != want {
			t.Fatalf("undo: %q, want %q", value, want)
		}
	}
}

type recordingInputHost struct {
	*headless
	states []platform.TextInputState
}

func (h *recordingInputHost) setTextInput(state platform.TextInputState) {
	h.states = append(h.states, state)
	h.headless.setTextInput(state)
}

func TestInputMethodFocusResetBetweenEditableFields(t *testing.T) {
	for _, second := range []string{"second", "first"} {
		t.Run(second, func(t *testing.T) {
			a, b := "first", second
			var first *editor
			tt := NewTester(func(c *Context) {
				Column(c).Children(func() {
					first = TextInput(c, &a).Size(260, 40).Label("A").st.editor
					TextInput(c, &b).Size(260, 40).Label("B")
				})
			}, 400, 180)
			host := &recordingInputHost{headless: tt.h}
			tt.rt.host = host
			tt.Click("A")
			tt.Command("selectAll")
			tt.Compose("xin", 3)
			if first.compose == "" || !host.ime.Active {
				t.Fatal("composition was not active")
			}
			host.states = nil
			tt.Click("B")
			if a != "first" || b != second || first.compose != "" {
				t.Fatal("focus change did not cancel the original editor's candidate")
			}
			// macOS's existing SetTextInput discards its native marked text
			// on this inactive transition before activating the next editor.
			if len(host.states) != 2 || host.states[0].Active || !host.states[1].Active || host.states[1].Text != b {
				t.Fatalf("host must deactivate A before activating B: %+v", host.states)
			}
			host.states = nil
			tt.Frame()
			if len(host.states) != 0 {
				t.Fatal("unchanged focus reset the input context again")
			}
		})
	}
}

func TestInputMethodFocusResetWithIdenticalState(t *testing.T) {
	a, b, useSecond := "same", "same", false
	tt := NewTester(func(c *Context) {
		// Overlapping equal-size inputs deliberately produce identical host
		// values, selection and caret geometry; only their identities differ.
		first := TextInput(c, &a).Absolute().Size(260, 40).Label("A")
		second := TextInput(c, &b).Absolute().Size(260, 40).Label("B")
		if useSecond {
			second.Focus()
		} else {
			first.Focus()
		}
	}, 400, 180)
	host := &recordingInputHost{headless: tt.h}
	tt.rt.host = host
	previous := host.ime
	useSecond = true
	tt.Frame()
	if len(host.states) != 2 || host.states[0].Active || host.states[1] != previous {
		t.Fatalf("identity-only focus change did not reset equal states: previous %+v, events %+v", previous, host.states)
	}
}

func TestInputMethodSameFieldDoesNotResetComposition(t *testing.T) {
	value := "原文"
	tt, ed := regressionInput(t, false, &value)
	host := &recordingInputHost{headless: tt.h}
	tt.rt.host = host
	tt.Command("selectAll")
	tt.Compose("xin", 3)
	host.states = nil
	tt.Frame()
	tt.Compose("新文", 2)
	for _, state := range host.states {
		if !state.Active {
			t.Fatal("same-field candidate update reset the input context")
		}
	}
	if ed.compose != "新文" || value != "原文" {
		t.Fatal("same-field candidate update lost composition or committed text")
	}
}

func TestInputMethodAppCancellationResetsHost(t *testing.T) {
	for _, action := range []string{"click", "key", "command", "set-text"} {
		t.Run(action, func(t *testing.T) {
			value := "旧文"
			tt, ed := regressionInput(t, false, &value)
			host := &recordingInputHost{headless: tt.h}
			tt.rt.host = host
			tt.Command("selectAll")
			tt.Compose("xin", 3)
			host.states = nil
			switch action {
			case "click":
				tt.Click("synthetic input")
			case "key":
				tt.Key(Cmd, KeyLeft)
			case "command":
				tt.Command("selectAll")
			case "set-text":
				value = "应用赋值"
				tt.Frame()
			}
			if ed.compose != "" {
				t.Fatal("Go candidate was not cancelled")
			}
			resets := 0
			for _, state := range host.states {
				if !state.Active {
					resets++
				}
			}
			if resets != 1 || !host.ime.Active {
				t.Fatalf("native cancellation requires one inactive transition then active: %+v", host.states)
			}
			host.states = nil
			tt.Frame()
			if len(host.states) != 0 {
				t.Fatal("consumed cancellation reset again")
			}
		})
	}
}

func TestInputMethodNativeFinishDoesNotResetHost(t *testing.T) {
	for _, finish := range []string{"unmark", "commit", "replace-candidate", "batched-unmark-new"} {
		t.Run(finish, func(t *testing.T) {
			value := "旧文"
			tt, ed := regressionInput(t, false, &value)
			host := &recordingInputHost{headless: tt.h}
			tt.rt.host = host
			tt.Command("selectAll")
			tt.Compose("xin", 3)
			host.states = nil
			switch finish {
			case "unmark":
				tt.Compose("", 0)
			case "commit":
				tt.Type("新文")
			case "replace-candidate":
				tt.send(platform.SurfaceEvent{Kind: platform.TextComposition, Text: "候选", Caret: 2, Replace: true, From: 0, To: 2})
			case "batched-unmark-new":
				tt.rt.editEvent(editEvent{kind: editCompose})
				tt.rt.editEvent(editEvent{kind: editInsert, text: "新文"})
				tt.rt.editEvent(editEvent{kind: editCompose, text: "hou", caret: 3})
				tt.Frame()
			}
			for _, state := range host.states {
				if !state.Active {
					t.Fatalf("native finish unnecessarily discarded context: %+v", host.states)
				}
			}
			if finish == "batched-unmark-new" && (value != "新文" || ed.compose != "hou") {
				t.Fatalf("new candidate lost: %q, %q", value, ed.compose)
			}
		})
	}
}

func TestInputMethodNativeEventSupersedesQueuedCancellation(t *testing.T) {
	for _, next := range []string{"candidate", "unmark", "commit-new-candidate"} {
		t.Run(next, func(t *testing.T) {
			value := "旧文"
			tt, ed := regressionInput(t, false, &value)
			host := &recordingInputHost{headless: tt.h}
			tt.rt.host = host
			tt.Command("selectAll")
			tt.Compose("xin", 3)
			host.states = nil
			// A later native callback may already be queued when a frame
			// processes an app command. Its newer context must not be reset
			// by the earlier cancellation after the whole queue is drained.
			tt.rt.editEvent(editEvent{kind: editCommand, text: "selectAll"})
			wantValue, wantCompose := "旧文", ""
			switch next {
			case "candidate":
				tt.rt.editEvent(editEvent{kind: editCompose, text: "hou", caret: 3})
				wantCompose = "hou"
			case "unmark":
				tt.rt.editEvent(editEvent{kind: editCompose})
			case "commit-new-candidate":
				tt.rt.editEvent(editEvent{kind: editCompose})
				tt.rt.editEvent(editEvent{kind: editInsert, text: "新文"})
				tt.rt.editEvent(editEvent{kind: editCompose, text: "hou", caret: 3})
				wantValue, wantCompose = "新文", "hou"
			}
			tt.Frame()
			for _, state := range host.states {
				if !state.Active {
					t.Fatal("earlier app cancellation discarded a newer native context")
				}
			}
			if value != wantValue || ed.compose != wantCompose {
				t.Fatalf("newer native event lost: value %q, compose %q", value, ed.compose)
			}
		})
	}
}
