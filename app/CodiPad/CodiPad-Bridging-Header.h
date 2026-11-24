#ifndef CODIPAD_BRIDGING_HEADER_H
#define CODIPAD_BRIDGING_HEADER_H

// Managed native Node runtime (C API only; no C++ types cross this boundary).
#import "../../native/CodiPadNode/NodeRuntime.h"
#import "../../native/CodiPadExecution/ExecutionRegion.h"
#import "../../native/CodiPadExecution/GuestMemoryWindow.h"

#import "../../native/CodiPadProcess/IshKernel.h"
#import "../../native/CodiPadProcess/ShellBootstrap.h"
#import "../../native/CodiPadProcess/NodeProcess.h"
#import "../../native/CodiPadExtensions/codipad_vsix_extract.h"

#endif  // CODIPAD_BRIDGING_HEADER_H
