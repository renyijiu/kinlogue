package main

import (
	"context"
	"errors"
	"fmt"
	"image"
	"os"

	"github.com/egoist/mygo"
	"kinlogue/internal/app"
	"kinlogue/internal/desktop"
	"kinlogue/internal/document"
	"kinlogue/internal/library"
	"kinlogue/internal/macos"
)

type appleProcessor struct{}

func (appleProcessor) Extract(c context.Context, b []byte) (document.Extraction, error) {
	return macos.Extract(c, b)
}
func (appleProcessor) RenderPage(c context.Context, b []byte, page int) (image.Image, error) {
	return macos.RenderPage(c, b, page)
}

func main() {
	// Code generation belongs to the mygo developer CLI, never this packaged
	// application. Production has no environment-based output or library root.
	_ = os.Unsetenv("MYGO_GENERATE")
	mygo.App.SetName("Kinlogue Go Preview")
	root, err := macos.LibraryRoot()
	if err != nil {
		startupFailure(err)
		return
	}
	runtime, err := library.OpenRuntime(root)
	if err != nil {
		startupFailure(err)
		return
	}
	runErr, closeErr := runLibrary(runtime, desktop.Run, desktop.RunRecovery)
	if runErr != nil {
		fmt.Fprintln(os.Stderr, "application_run_failed")
	}
	if closeErr != nil {
		fmt.Fprintln(os.Stderr, "application_close_failed")
	}
}

func runLibrary(runtime *library.Runtime, run func(desktop.Backend, desktop.BackupBackend, bool) error, recover func(desktop.BackupBackend) error) (runErr, closeErr error) {
	if store := runtime.Store(); store != nil {
		service := app.New(store, appleProcessor{}, macos.ReadImportedFile, macos.WriteExport)
		if err := service.ConfigureLAN(app.LANConfig{Interfaces: macos.LANInterfaces, Listen: macos.ListenLAN, Watch: macos.WatchLANInterface}); err != nil {
			return err, service.Close()
		}
		controller := app.NewBackupController(runtime, service, macos.WriteBackup, macos.ReadBackup)
		runErr = run(service, controller, runtime.OpenError() != nil)
		return runErr, controller.Close()
	}
	controller := app.NewRecoveryController(runtime, macos.ReadBackup)
	runErr = recover(controller)
	return runErr, controller.Close()
}

func startupFailure(err error) {
	title, message, button := startupText(macos.PreferredLanguage(), errors.Is(err, library.ErrLocked))
	mygo.App.WhenReady(func() {
		go func() {
			_, _ = mygo.Dialog.Message(mygo.MessageOptions{Type: mygo.MessageError, Title: title, Message: message, Buttons: []string{button}})
			mygo.App.Quit()
		}()
	})
	if runErr := mygo.App.Run(); runErr != nil {
		fmt.Fprintln(os.Stderr, "application_start_failed")
	}
}

func startupText(language string, locked bool) (string, string, string) {
	if language == "zh-Hans" {
		message := "无法打开预览版资料库。请使用构建后的应用包启动，并确认资料目录可用。"
		if locked {
			message = "预览版资料库正在使用中。请先退出另一个预览版窗口，再重新打开。"
		}
		return "续页 Go 预览", message, "退出"
	}
	message := "The preview library could not be opened. Launch the built app bundle and check that its library directory is available."
	if locked {
		message = "The preview library is already in use. Quit the other preview instance and try again."
	}
	return "Kinlogue Go Preview", message, "Quit"
}
