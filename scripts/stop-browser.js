ObjC.import('AppKit');

function run(arguments) {
    let count = 0;
    for (const identifier of ['dev.athas.browser', 'dev.athas.browser.debug']) {
        const applications = $.NSRunningApplication.runningApplicationsWithBundleIdentifier(identifier);
        for (let index = 0; index < applications.count; index++) {
            const application = applications.objectAtIndex(index);
            // The filename exception recognizes Debug installs from before identities were split.
            const isDebug = identifier === 'dev.athas.browser.debug'
                || ObjC.unwrap(application.bundleURL.lastPathComponent) === 'Browser-Debug.app';
            if (arguments[1] && isDebug !== (arguments[1] === 'Browser-Debug')) continue;
            count += 1;
            if (arguments[0] === 'quit') application.terminate;
        }
    }
    return count;
}
