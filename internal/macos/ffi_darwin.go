//go:build darwin

// Package macos is the bounded adapter to public Apple document APIs. Native
// objects never escape a serialized, locked-thread autorelease-pool lifetime.
package macos

import (
	"context"
	"runtime"
	"sync"
	"unsafe"

	"github.com/ebitengine/purego"
	"github.com/ebitengine/purego/objc"
	"kinlogue/internal/document"
)

type id = objc.ID
type point struct{ X, Y float64 }
type size struct{ Width, Height float64 }
type rect struct {
	Origin point
	Size   size
}
type affine struct{ A, B, C, D, TX, TY float64 }
type nsRange struct{ Location, Length uintptr }

var nativeMu sync.Mutex
var loadOnce sync.Once
var loadErr error
var msgAddr uintptr
var poolPush func() uintptr
var poolPop func(uintptr)
var msgRect func(id, objc.SEL) rect
var msgRectArg func(id, objc.SEL, uintptr) rect
var msgRange func(id, objc.SEL, nsRange) id
var msgConfidence func(id, objc.SEL) float32
var cfRelease func(uintptr)
var sourceCreate func(id, id) uintptr
var sourceCount func(uintptr) uintptr
var sourceType func(uintptr) id
var sourceProperties func(uintptr, uintptr, id) id
var sourceThumbnail func(uintptr, uintptr, id) uintptr
var imageWidth, imageHeight func(uintptr) uintptr
var imageRelease func(uintptr)
var colorSpaceCreate func() uintptr
var colorSpaceRelease func(uintptr)
var bitmapCreate func(uintptr, uintptr, uintptr, uintptr, uintptr, uintptr, uint32) uintptr
var bitmapImage func(uintptr) uintptr
var bitmapData func(uintptr) uintptr
var contextRelease func(uintptr)
var contextFillColor func(uintptr, float64, float64, float64, float64)
var contextFillRect func(uintptr, rect)
var contextDrawImage func(uintptr, rect, uintptr)
var contextConcat func(uintptr, affine)
var pdfRotation func(uintptr) int32
var imageKeys = map[string]id{}

// Load only fixed system frameworks. Errors deliberately omit loader diagnostics.
func load() error {
	loadOnce.Do(func() {
		libs := make(map[string]uintptr)
		for _, name := range []string{"Foundation", "CoreFoundation", "CoreGraphics", "ImageIO", "PDFKit", "Vision"} {
			h, err := purego.Dlopen("/System/Library/Frameworks/"+name+".framework/"+name, purego.RTLD_NOW|purego.RTLD_GLOBAL)
			if err != nil {
				loadErr = document.ErrUnavailable
				return
			}
			libs[name] = h
		}
		objcLib, err := purego.Dlopen("/usr/lib/libobjc.A.dylib", purego.RTLD_NOW|purego.RTLD_GLOBAL)
		if err != nil {
			loadErr = document.ErrUnavailable
			return
		}
		bind := func(fn any, lib uintptr, name string) {
			if loadErr != nil {
				return
			}
			p, err := purego.Dlsym(lib, name)
			if err != nil {
				loadErr = document.ErrUnavailable
				return
			}
			purego.RegisterFunc(fn, p)
		}
		msgAddr, err = purego.Dlsym(objcLib, "objc_msgSend")
		if err != nil {
			loadErr = document.ErrUnavailable
			return
		}
		stret := msgAddr
		if runtime.GOARCH == "amd64" {
			stret, err = purego.Dlsym(objcLib, "objc_msgSend_stret")
			if err != nil {
				loadErr = document.ErrUnavailable
				return
			}
		}
		purego.RegisterFunc(&msgRect, stret)
		purego.RegisterFunc(&msgRectArg, stret)
		purego.RegisterFunc(&msgRange, msgAddr)
		purego.RegisterFunc(&msgConfidence, msgAddr)
		bind(&poolPush, objcLib, "objc_autoreleasePoolPush")
		bind(&poolPop, objcLib, "objc_autoreleasePoolPop")
		bind(&cfRelease, libs["CoreFoundation"], "CFRelease")
		bind(&sourceCreate, libs["ImageIO"], "CGImageSourceCreateWithData")
		bind(&sourceCount, libs["ImageIO"], "CGImageSourceGetCount")
		bind(&sourceType, libs["ImageIO"], "CGImageSourceGetType")
		bind(&sourceProperties, libs["ImageIO"], "CGImageSourceCopyPropertiesAtIndex")
		bind(&sourceThumbnail, libs["ImageIO"], "CGImageSourceCreateThumbnailAtIndex")
		for _, name := range []string{"kCGImageSourceShouldCache", "kCGImageSourceShouldCacheImmediately", "kCGImageSourceCreateThumbnailFromImageAlways", "kCGImageSourceCreateThumbnailWithTransform", "kCGImageSourceThumbnailMaxPixelSize", "kCGImagePropertyPixelWidth", "kCGImagePropertyPixelHeight"} {
			p, err := purego.Dlsym(libs["ImageIO"], name)
			if err != nil {
				loadErr = document.ErrUnavailable
				return
			}
			imageKeys[name] = **(**id)(unsafe.Pointer(&p))
		}
		cg := libs["CoreGraphics"]
		bind(&imageWidth, cg, "CGImageGetWidth")
		bind(&imageHeight, cg, "CGImageGetHeight")
		bind(&imageRelease, cg, "CGImageRelease")
		bind(&colorSpaceCreate, cg, "CGColorSpaceCreateDeviceRGB")
		bind(&colorSpaceRelease, cg, "CGColorSpaceRelease")
		bind(&bitmapCreate, cg, "CGBitmapContextCreate")
		bind(&bitmapImage, cg, "CGBitmapContextCreateImage")
		bind(&bitmapData, cg, "CGBitmapContextGetData")
		bind(&contextRelease, cg, "CGContextRelease")
		bind(&contextFillColor, cg, "CGContextSetRGBFillColor")
		bind(&contextFillRect, cg, "CGContextFillRect")
		bind(&contextConcat, cg, "CGContextConcatCTM")
		bind(&contextDrawImage, cg, "CGContextDrawImage")
		bind(&pdfRotation, cg, "CGPDFPageGetRotationAngle")
	})
	return loadErr
}

func native(ctx context.Context, fn func() error) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	nativeMu.Lock()
	defer nativeMu.Unlock()
	if err := ctx.Err(); err != nil {
		return err
	}
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()
	if err := load(); err != nil {
		return err
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	pool := poolPush()
	defer poolPop(pool)
	err := fn()
	// Synchronous Apple calls cannot be forcibly interrupted; discard late output.
	if canceled := ctx.Err(); canceled != nil {
		return canceled
	}
	return err
}

//go:uintptrescapes
func send(obj id, selector string, args ...uintptr) id {
	a := make([]uintptr, len(args)+2)
	a[0], a[1] = uintptr(obj), uintptr(objc.RegisterName(selector))
	copy(a[2:], args)
	r, _, _ := purego.SyscallN(msgAddr, a...)
	return id(r)
}
func class(name string) id { return id(objc.GetClass(name)) }
func release(obj id) {
	if obj != 0 {
		send(obj, "release")
	}
}
func alloc(name string) id { return send(class(name), "alloc") }
func nsString(s string) id {
	obj := send(alloc("NSString"), "initWithBytes:length:encoding:", uintptr(unsafe.Pointer(unsafe.StringData(s))), uintptr(len(s)), 4)
	runtime.KeepAlive(s)
	return send(obj, "autorelease")
}
func nsData(b []byte) id {
	obj := send(class("NSData"), "dataWithBytes:length:", uintptr(unsafe.Pointer(unsafe.SliceData(b))), uintptr(len(b)))
	runtime.KeepAlive(b)
	return obj
}
func stringCopy(obj id, limit int) (string, error) {
	if obj == 0 {
		return "", nil
	}
	n := uint64(send(obj, "lengthOfBytesUsingEncoding:", 4))
	if n > uint64(limit) {
		return "", document.ErrLimit
	}
	if n == 0 {
		return "", nil
	}
	p := send(obj, "UTF8String")
	if p == 0 {
		return "", document.ErrInvalid
	}
	return string(unsafe.Slice(*(**byte)(unsafe.Pointer(&p)), int(n))), nil
}
func nsArray(objects ...id) id {
	a := send(class("NSMutableArray"), "arrayWithCapacity:", uintptr(len(objects)))
	for _, obj := range objects {
		send(a, "addObject:", uintptr(obj))
	}
	return a
}
func nsDict(entries map[string]id) id {
	d := send(class("NSMutableDictionary"), "dictionaryWithCapacity:", uintptr(len(entries)))
	for key, value := range entries {
		send(d, "setObject:forKey:", uintptr(value), uintptr(nsString(key)))
	}
	return d
}
func number(value int) id { return send(class("NSNumber"), "numberWithInteger:", uintptr(value)) }
func imageOptions(entries map[string]int) id {
	d := send(class("NSMutableDictionary"), "dictionaryWithCapacity:", uintptr(len(entries)))
	for key, value := range entries {
		v := number(value)
		if key != "kCGImageSourceThumbnailMaxPixelSize" {
			v = send(class("NSNumber"), "numberWithBool:", uintptr(value))
		}
		send(d, "setObject:forKey:", uintptr(v), uintptr(imageKeys[key]))
	}
	return d
}
