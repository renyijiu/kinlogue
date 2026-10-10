package desktop

import "github.com/egoist/mygo/ui"

// Simple line icons drawn for Kinlogue. They take the text color like the
// Swift app's symbols but are original geometry, not copies of SF Symbols.
func lineIcon(body string) *ui.SVG {
	return ui.MustParseSVG([]byte(`<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="24" height="24"><g fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">` + body + `</g></svg>`))
}

var (
	iconClock      = lineIcon(`<circle cx="12" cy="12" r="8.5"/><path d="M12 7.5V12l3 2"/>`)
	iconTray       = lineIcon(`<path d="M3.5 13.5h4.5l1.5 2.5h5l1.5-2.5h4.5"/><path d="M3.5 13.5 6 6.5h3M18 6.5h-3M20.5 13.5 18 6.5"/><path d="M3.5 13.5V19h17v-5.5"/><path d="M12 3.5v8M9 8.5l3 3 3-3"/>`)
	iconWaves      = lineIcon(`<circle cx="12" cy="12" r="1.6"/><path d="M8.5 8.5a5 5 0 0 0 0 7M15.5 8.5a5 5 0 0 1 0 7M5.6 5.6a9 9 0 0 0 0 12.8M18.4 5.6a9 9 0 0 1 0 12.8"/>`)
	iconPerson     = lineIcon(`<circle cx="12" cy="8" r="3.6"/><path d="M4.8 20c.6-3.8 3.6-5.8 7.2-5.8s6.6 2 7.2 5.8"/>`)
	iconPersonPlus = lineIcon(`<circle cx="10" cy="8" r="3.6"/><path d="M3 20c.6-3.8 3.4-5.8 7-5.8 1.6 0 3 .4 4.2 1.1"/><path d="M18 14v6M15 17h6"/>`)
	iconGear       = lineIcon(`<circle cx="12" cy="12" r="3"/><path d="M12 3v2.5M12 18.5V21M3 12h2.5M18.5 12H21M5.6 5.6l1.8 1.8M16.6 16.6l1.8 1.8M5.6 18.4l1.8-1.8M16.6 7.4l1.8-1.8"/>`)
	iconDocClock   = lineIcon(`<path d="M13 3.5H6.5v17H11"/><path d="M13 3.5 17.5 8v2"/><path d="M13 3.5V8h4.5"/><circle cx="16.5" cy="16.5" r="4"/><path d="M16.5 14.5v2l1.4 1"/>`)
	iconHourglass  = lineIcon(`<path d="M7 3.5h10M7 20.5h10"/><path d="M8 3.5c0 4 8 5 8 8.5s-8 4.5-8 8.5M16 3.5c0 4-8 5-8 8.5s8 4.5 8 8.5"/>`)
	iconRetry      = lineIcon(`<path d="M19.5 12a7.5 7.5 0 1 1-2.2-5.3"/><path d="M19.5 4v4.5H15"/>`)
	iconTrash      = lineIcon(`<path d="M4.5 7h15M9.5 7V4.5h5V7"/><path d="M6.5 7l1 13h9l1-13"/><path d="M10 11v5.5M14 11v5.5"/>`)
	iconChevron    = lineIcon(`<path d="M9.5 6l6 6-6 6"/>`)
	iconBack       = lineIcon(`<path d="M14.5 6l-6 6 6 6"/>`)
	iconSearch     = lineIcon(`<circle cx="10.5" cy="10.5" r="6"/><path d="M15 15l5 5"/>`)
	iconClear      = lineIcon(`<circle cx="12" cy="12" r="8.5"/><path d="M9 9l6 6M15 9l-6 6"/>`)
	iconDoc        = lineIcon(`<path d="M14 3.5H6.5v17h11V7z"/><path d="M14 3.5V7h3.5"/><path d="M9 12h6M9 15.5h6"/>`)
	iconList       = lineIcon(`<rect x="3.5" y="4.5" width="17" height="15" rx="2"/><path d="M7.5 9h.01M10.5 9h6M7.5 12.5h.01M10.5 12.5h6M7.5 16h.01M10.5 16h6"/>`)
	iconNote       = lineIcon(`<path d="M5 4.5h14v15H5z"/><path d="M8.5 9h7M8.5 12.5h7M8.5 16h4"/>`)
	iconEye        = lineIcon(`<path d="M2.5 12S6 5.5 12 5.5 21.5 12 21.5 12 18 18.5 12 18.5 2.5 12 2.5 12z"/><circle cx="12" cy="12" r="3"/>`)
	iconUp         = lineIcon(`<path d="M12 19V5M6 11l6-6 6 6"/>`)
	iconDown       = lineIcon(`<path d="M12 5v14M6 13l6 6 6-6"/>`)
	iconCheck      = lineIcon(`<circle cx="12" cy="12" r="8.5"/><path d="M8 12.3l2.7 2.7L16 9.5"/>`)
	iconWarning    = lineIcon(`<path d="M12 4 2.8 19.5h18.4z"/><path d="M12 10v4.5M12 17.2h.01"/>`)
	iconScan       = lineIcon(`<path d="M4 8V4h4M16 4h4v4M20 16v4h-4M8 20H4v-4"/><path d="M8 10h8M8 14h5"/>`)
	iconNo         = lineIcon(`<circle cx="12" cy="12" r="8.5"/><path d="M6 6l12 12"/>`)
	iconPhone      = lineIcon(`<rect x="5" y="2.5" width="9" height="19" rx="2"/><path d="M8.5 18.5h2"/><path d="M14 12h7M18 9l3 3-3 3"/>`)
	iconImport     = lineIcon(`<path d="M7 10.5l5 5 5-5M12 3.5v12"/><path d="M4.5 15v4.5h15V15"/>`)
	iconShield     = lineIcon(`<path d="M12 3.5 5 6v5.5c0 4.3 3 7.6 7 9 4-1.4 7-4.7 7-9V6z"/><path d="M12 9v4M12 15.8h.01"/>`)
	iconDrive      = lineIcon(`<rect x="3.5" y="13" width="17" height="6.5" rx="1.8"/><path d="M5.5 13 7.8 5.5h8.4L18.5 13"/><path d="M16.5 16.3h.01"/>`)
	iconSliders    = lineIcon(`<path d="M4 7h9M17 7h3M4 17h3M11 17h9"/><circle cx="15" cy="7" r="2"/><circle cx="9" cy="17" r="2"/>`)
	iconMore       = lineIcon(`<path d="M6 12h.01M12 12h.01M18 12h.01" stroke-width="3"/>`)
	iconTick       = lineIcon(`<path d="M5 12.5l4.5 4.5L19 7.5" stroke-width="2.4"/>`)
	iconBuilding   = lineIcon(`<path d="M5 20.5V4.5h9v16M14 9.5h5v11M3.5 20.5h17"/><path d="M8 8h3M8 11.5h3M8 15h3"/>`)
	iconQuote      = lineIcon(`<path d="M4.5 6.5h15M4.5 11h15M4.5 15.5h9"/><path d="M16.5 15.5v3.5M19.5 15.5v3.5"/>`)
	iconSeal       = lineIcon(`<circle cx="12" cy="12" r="8.5"/><path d="M8 12.3l2.7 2.7L16 9.5"/>`)
)

// icon draws a line icon at size, in color.
func icon(c *ui.Context, svg *ui.SVG, size float32, color ui.Color) *ui.Element {
	return ui.Icon(c, svg).Size(size, size).Shrink(0).TextColor(color)
}
