public enum PopoverDismissalPolicy {
    public static func shouldClose(isGlobalClick: Bool, isPopoverWindow: Bool,
                                   isStatusItemWindow: Bool) -> Bool {
        isGlobalClick || (!isPopoverWindow && !isStatusItemWindow)
    }
}
