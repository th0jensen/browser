ObjC.import('AppKit');

function run(arguments) {
    let count = 0;
    for (const identifier of ['dev.athas.browser', 'dev.athas.browser.debug']) {
        const applications = $.NSRunningApplication.runningApplicationsWithBundleIdentifier(identifier);
        count += Number(applications.count);
        if (arguments[0] === 'quit') {
            for (let index = 0; index < applications.count; index++) applications.objectAtIndex(index).terminate;
        }
    }
    return count;
}
