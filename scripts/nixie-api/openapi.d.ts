// Generated from openapi.json beside it by `bun run nixie:openapi <tag>`: never edit it by hand.

export interface paths {
    "/conversation/read": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        get?: never;
        put?: never;
        post: operations["conversation.read"];
        delete?: never;
        options?: never;
        head?: never;
        patch?: never;
        trace?: never;
    };
    "/conversation/send": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        get?: never;
        put?: never;
        post: operations["conversation.send"];
        delete?: never;
        options?: never;
        head?: never;
        patch?: never;
        trace?: never;
    };
    "/conversation/readImage": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        get?: never;
        put?: never;
        post: operations["conversation.readImage"];
        delete?: never;
        options?: never;
        head?: never;
        patch?: never;
        trace?: never;
    };
    "/conversation/forget": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        get?: never;
        put?: never;
        post: operations["conversation.forget"];
        delete?: never;
        options?: never;
        head?: never;
        patch?: never;
        trace?: never;
    };
    "/memory/readVersions": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        get?: never;
        put?: never;
        post: operations["memory.readVersions"];
        delete?: never;
        options?: never;
        head?: never;
        patch?: never;
        trace?: never;
    };
    "/memory/readRatingNotes": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        get?: never;
        put?: never;
        post: operations["memory.readRatingNotes"];
        delete?: never;
        options?: never;
        head?: never;
        patch?: never;
        trace?: never;
    };
    "/memory/writerStatus": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        get?: never;
        put?: never;
        post: operations["memory.writerStatus"];
        delete?: never;
        options?: never;
        head?: never;
        patch?: never;
        trace?: never;
    };
    "/memory/consolidatorStatus": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        get?: never;
        put?: never;
        post: operations["memory.consolidatorStatus"];
        delete?: never;
        options?: never;
        head?: never;
        patch?: never;
        trace?: never;
    };
    "/memory/listItems": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        get?: never;
        put?: never;
        post: operations["memory.listItems"];
        delete?: never;
        options?: never;
        head?: never;
        patch?: never;
        trace?: never;
    };
    "/memory/findItems": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        get?: never;
        put?: never;
        post: operations["memory.findItems"];
        delete?: never;
        options?: never;
        head?: never;
        patch?: never;
        trace?: never;
    };
    "/memory/readPinnedCore": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        get?: never;
        put?: never;
        post: operations["memory.readPinnedCore"];
        delete?: never;
        options?: never;
        head?: never;
        patch?: never;
        trace?: never;
    };
    "/memory/readItem": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        get?: never;
        put?: never;
        post: operations["memory.readItem"];
        delete?: never;
        options?: never;
        head?: never;
        patch?: never;
        trace?: never;
    };
    "/memory/retire": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        get?: never;
        put?: never;
        post: operations["memory.retire"];
        delete?: never;
        options?: never;
        head?: never;
        patch?: never;
        trace?: never;
    };
    "/memory/restore": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        get?: never;
        put?: never;
        post: operations["memory.restore"];
        delete?: never;
        options?: never;
        head?: never;
        patch?: never;
        trace?: never;
    };
    "/memory/listNotices": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        get?: never;
        put?: never;
        post: operations["memory.listNotices"];
        delete?: never;
        options?: never;
        head?: never;
        patch?: never;
        trace?: never;
    };
    "/memory/undo": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        get?: never;
        put?: never;
        post: operations["memory.undo"];
        delete?: never;
        options?: never;
        head?: never;
        patch?: never;
        trace?: never;
    };
    "/memory/keep": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        get?: never;
        put?: never;
        post: operations["memory.keep"];
        delete?: never;
        options?: never;
        head?: never;
        patch?: never;
        trace?: never;
    };
    "/memory/previewForget": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        get?: never;
        put?: never;
        post: operations["memory.previewForget"];
        delete?: never;
        options?: never;
        head?: never;
        patch?: never;
        trace?: never;
    };
    "/memory/forget": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        get?: never;
        put?: never;
        post: operations["memory.forget"];
        delete?: never;
        options?: never;
        head?: never;
        patch?: never;
        trace?: never;
    };
    "/memory/previewForgetRetired": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        get?: never;
        put?: never;
        post: operations["memory.previewForgetRetired"];
        delete?: never;
        options?: never;
        head?: never;
        patch?: never;
        trace?: never;
    };
    "/memory/forgetRetired": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        get?: never;
        put?: never;
        post: operations["memory.forgetRetired"];
        delete?: never;
        options?: never;
        head?: never;
        patch?: never;
        trace?: never;
    };
    "/memory/readForgetStatus": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        get?: never;
        put?: never;
        post: operations["memory.readForgetStatus"];
        delete?: never;
        options?: never;
        head?: never;
        patch?: never;
        trace?: never;
    };
    "/memory/pin": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        get?: never;
        put?: never;
        post: operations["memory.pin"];
        delete?: never;
        options?: never;
        head?: never;
        patch?: never;
        trace?: never;
    };
    "/memory/markSensitive": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        get?: never;
        put?: never;
        post: operations["memory.markSensitive"];
        delete?: never;
        options?: never;
        head?: never;
        patch?: never;
        trace?: never;
    };
    "/memory/listProposals": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        get?: never;
        put?: never;
        post: operations["memory.listProposals"];
        delete?: never;
        options?: never;
        head?: never;
        patch?: never;
        trace?: never;
    };
    "/memory/approveProposals": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        get?: never;
        put?: never;
        post: operations["memory.approveProposals"];
        delete?: never;
        options?: never;
        head?: never;
        patch?: never;
        trace?: never;
    };
    "/memory/rejectProposals": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        get?: never;
        put?: never;
        post: operations["memory.rejectProposals"];
        delete?: never;
        options?: never;
        head?: never;
        patch?: never;
        trace?: never;
    };
    "/memory/export": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        get?: never;
        put?: never;
        post: operations["memory.export"];
        delete?: never;
        options?: never;
        head?: never;
        patch?: never;
        trace?: never;
    };
    "/memory/keepMoment": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        get?: never;
        put?: never;
        post: operations["memory.keepMoment"];
        delete?: never;
        options?: never;
        head?: never;
        patch?: never;
        trace?: never;
    };
    "/memory/listMoments": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        get?: never;
        put?: never;
        post: operations["memory.listMoments"];
        delete?: never;
        options?: never;
        head?: never;
        patch?: never;
        trace?: never;
    };
    "/memory/readMoment": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        get?: never;
        put?: never;
        post: operations["memory.readMoment"];
        delete?: never;
        options?: never;
        head?: never;
        patch?: never;
        trace?: never;
    };
    "/memory/readMomentSpan": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        get?: never;
        put?: never;
        post: operations["memory.readMomentSpan"];
        delete?: never;
        options?: never;
        head?: never;
        patch?: never;
        trace?: never;
    };
    "/memory/editMoment": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        get?: never;
        put?: never;
        post: operations["memory.editMoment"];
        delete?: never;
        options?: never;
        head?: never;
        patch?: never;
        trace?: never;
    };
    "/memory/linkMoment": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        get?: never;
        put?: never;
        post: operations["memory.linkMoment"];
        delete?: never;
        options?: never;
        head?: never;
        patch?: never;
        trace?: never;
    };
    "/memory/previewMomentDestroy": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        get?: never;
        put?: never;
        post: operations["memory.previewMomentDestroy"];
        delete?: never;
        options?: never;
        head?: never;
        patch?: never;
        trace?: never;
    };
    "/memory/destroyMoment": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        get?: never;
        put?: never;
        post: operations["memory.destroyMoment"];
        delete?: never;
        options?: never;
        head?: never;
        patch?: never;
        trace?: never;
    };
    "/log/follow": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        get?: never;
        put?: never;
        /** @deprecated */
        post: operations["log.follow"];
        delete?: never;
        options?: never;
        head?: never;
        patch?: never;
        trace?: never;
    };
    "/records/follow": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        get?: never;
        put?: never;
        post: operations["records.follow"];
        delete?: never;
        options?: never;
        head?: never;
        patch?: never;
        trace?: never;
    };
    "/sessions/enrol": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        get?: never;
        put?: never;
        post: operations["sessions.enrol"];
        delete?: never;
        options?: never;
        head?: never;
        patch?: never;
        trace?: never;
    };
    "/sessions/issueCode": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        get?: never;
        put?: never;
        post: operations["sessions.issueCode"];
        delete?: never;
        options?: never;
        head?: never;
        patch?: never;
        trace?: never;
    };
    "/sessions/list": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        get?: never;
        put?: never;
        post: operations["sessions.list"];
        delete?: never;
        options?: never;
        head?: never;
        patch?: never;
        trace?: never;
    };
    "/sessions/revoke": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        get?: never;
        put?: never;
        post: operations["sessions.revoke"];
        delete?: never;
        options?: never;
        head?: never;
        patch?: never;
        trace?: never;
    };
}
export type webhooks = Record<string, never>;
export interface components {
    schemas: never;
    responses: never;
    parameters: never;
    requestBodies: never;
    headers: never;
    pathItems: never;
}
export type $defs = Record<string, never>;
export interface operations {
    "conversation.read": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        requestBody: {
            content: {
                "application/json": {
                    beforeSequence?: number;
                    limit?: number;
                    thread: string;
                };
            };
        };
        responses: {
            /** @description OK */
            200: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        hasEarlier: boolean;
                        readAtSequence: number;
                        records: {
                            compaction?: {
                                postTokens?: number;
                                preTokens: number;
                                /** @enum {string} */
                                trigger: "manual" | "auto";
                            };
                            compactionFailure?: {
                                failures: number;
                            };
                            forget?: {
                                sequence: number;
                            };
                            context?: {
                                size: number;
                                window: number;
                            };
                            kind: string;
                            message?: {
                                /** Format: uuid */
                                clientMessageId?: string;
                                images?: {
                                    /** @enum {string} */
                                    mediaType: "image/jpeg" | "image/png" | "image/webp" | "image/gif";
                                }[];
                                spans?: {
                                    end: number;
                                    /** @enum {string} */
                                    source: "typed" | "pasted" | "dropped" | "unknown";
                                    start: number;
                                }[];
                                text: string;
                            };
                            moment?: {
                                momentID: string;
                                shortID: string;
                                title?: string;
                            };
                            rating?: {
                                items: {
                                    itemID: string;
                                    version: number;
                                    hasNote: boolean;
                                    /** @enum {string} */
                                    verdict: "helpful" | "noise" | "misleading";
                                }[];
                                ratedBy?: string;
                                recalledSequence: number;
                            };
                            recall?: {
                                items: {
                                    itemID: string;
                                    version: number;
                                    score?: number;
                                }[];
                            };
                            /** Format: date-time */
                            recordedAt: string;
                            sequence: number;
                            summary?: {
                                contextSize?: number;
                                summaryTokens: number;
                                text?: string;
                                /** @enum {string} */
                                trigger: "threshold" | "overflow";
                            };
                            thread: string;
                            task?: {
                                error?: string;
                                errorLimit?: number;
                                errors?: number;
                                /** Format: date-time */
                                retryAt?: string;
                                stepKey?: string;
                                taskID: string;
                            };
                            toolCall?: {
                                callID: string;
                                content?: {
                                    [key: string]: unknown;
                                };
                                input?: {
                                    [key: string]: unknown;
                                };
                                outcome?: string;
                                tool?: string;
                            };
                        }[];
                        lastStepEnd?: {
                            compaction?: {
                                postTokens?: number;
                                preTokens: number;
                                /** @enum {string} */
                                trigger: "manual" | "auto";
                            };
                            compactionFailure?: {
                                failures: number;
                            };
                            forget?: {
                                sequence: number;
                            };
                            context?: {
                                size: number;
                                window: number;
                            };
                            kind: string;
                            message?: {
                                /** Format: uuid */
                                clientMessageId?: string;
                                images?: {
                                    /** @enum {string} */
                                    mediaType: "image/jpeg" | "image/png" | "image/webp" | "image/gif";
                                }[];
                                spans?: {
                                    end: number;
                                    /** @enum {string} */
                                    source: "typed" | "pasted" | "dropped" | "unknown";
                                    start: number;
                                }[];
                                text: string;
                            };
                            moment?: {
                                momentID: string;
                                shortID: string;
                                title?: string;
                            };
                            rating?: {
                                items: {
                                    itemID: string;
                                    version: number;
                                    hasNote: boolean;
                                    /** @enum {string} */
                                    verdict: "helpful" | "noise" | "misleading";
                                }[];
                                ratedBy?: string;
                                recalledSequence: number;
                            };
                            recall?: {
                                items: {
                                    itemID: string;
                                    version: number;
                                    score?: number;
                                }[];
                            };
                            /** Format: date-time */
                            recordedAt: string;
                            sequence: number;
                            summary?: {
                                contextSize?: number;
                                summaryTokens: number;
                                text?: string;
                                /** @enum {string} */
                                trigger: "threshold" | "overflow";
                            };
                            thread: string;
                            task?: {
                                error?: string;
                                errorLimit?: number;
                                errors?: number;
                                /** Format: date-time */
                                retryAt?: string;
                                stepKey?: string;
                                taskID: string;
                            };
                            toolCall?: {
                                callID: string;
                                content?: {
                                    [key: string]: unknown;
                                };
                                input?: {
                                    [key: string]: unknown;
                                };
                                outcome?: string;
                                tool?: string;
                            };
                        } | null;
                    };
                };
            };
            /** @description 401 */
            401: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "UNAUTHORIZED";
                        /** @constant */
                        status: 401;
                        /** @default The device session is missing, lapsed or revoked */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: false;
                        code: string;
                        status: number;
                        message: string;
                        data?: unknown;
                    };
                };
            };
            /** @description 404 */
            404: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "THREAD_NOT_FOUND";
                        /** @constant */
                        status: 404;
                        /** @default No thread has this ID */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: false;
                        code: string;
                        status: number;
                        message: string;
                        data?: unknown;
                    };
                };
            };
        };
    };
    "conversation.send": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        requestBody: {
            content: {
                "application/json": {
                    /** Format: uuid */
                    clientMessageId: string;
                    images?: string[];
                    spans: {
                        end: number;
                        /** @enum {string} */
                        source: "typed" | "pasted" | "dropped" | "unknown";
                        start: number;
                    }[];
                    text: string;
                    thread: string;
                    timeZone?: string;
                    /** Format: date-time */
                    writtenAt?: string;
                };
                "multipart/form-data": {
                    /** Format: uuid */
                    clientMessageId: string;
                    images?: string[];
                    spans: {
                        end: number;
                        /** @enum {string} */
                        source: "typed" | "pasted" | "dropped" | "unknown";
                        start: number;
                    }[];
                    text: string;
                    thread: string;
                    timeZone?: string;
                    /** Format: date-time */
                    writtenAt?: string;
                };
            };
        };
        responses: {
            /** @description OK */
            200: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        duplicate: boolean;
                        sequence: number;
                    };
                };
            };
            /** @description 401 */
            401: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "UNAUTHORIZED";
                        /** @constant */
                        status: 401;
                        /** @default The device session is missing, lapsed or revoked */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: false;
                        code: string;
                        status: number;
                        message: string;
                        data?: unknown;
                    };
                };
            };
            /** @description 404 */
            404: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "THREAD_NOT_FOUND";
                        /** @constant */
                        status: 404;
                        /** @default No thread has this ID */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: false;
                        code: string;
                        status: number;
                        message: string;
                        data?: unknown;
                    };
                };
            };
            /** @description 409 */
            409: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "CLIENT_ACTION_ID_REUSED";
                        /** @constant */
                        status: 409;
                        /** @default The client action ID belongs to a different action */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: false;
                        code: string;
                        status: number;
                        message: string;
                        data?: unknown;
                    };
                };
            };
            /** @description 422 */
            422: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "IMAGE_REFUSED";
                        /** @constant */
                        status: 422;
                        /** @default An image is too large, of a type nixie does not take, or one too many */
                        message: string;
                        data: {
                            position: number | null;
                            /** @enum {string} */
                            reason: "too_many" | "too_large" | "unsupported_type";
                        };
                    } | {
                        /** @constant */
                        defined: false;
                        code: string;
                        status: number;
                        message: string;
                        data?: unknown;
                    };
                };
            };
        };
    };
    "conversation.readImage": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        requestBody: {
            content: {
                "application/json": {
                    position: number;
                    sequence: number;
                    thread: string;
                };
            };
        };
        responses: {
            /** @description OK */
            200: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "*/*": string;
                };
            };
            /** @description 401 */
            401: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "UNAUTHORIZED";
                        /** @constant */
                        status: 401;
                        /** @default The device session is missing, lapsed or revoked */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: false;
                        code: string;
                        status: number;
                        message: string;
                        data?: unknown;
                    };
                };
            };
            /** @description 404 */
            404: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "IMAGE_NOT_FOUND";
                        /** @constant */
                        status: 404;
                        /** @default No readable image of a message has this position */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: false;
                        code: string;
                        status: number;
                        message: string;
                        data?: unknown;
                    };
                };
            };
        };
    };
    "conversation.forget": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        requestBody: {
            content: {
                "application/json": {
                    /** Format: uuid */
                    clientActionID: string;
                    sequence: number;
                    thread: string;
                };
            };
        };
        responses: {
            /** @description OK */
            200: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** Format: date-time */
                        forgottenAt: string;
                    };
                };
            };
            /** @description 401 */
            401: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "UNAUTHORIZED";
                        /** @constant */
                        status: 401;
                        /** @default The device session is missing, lapsed or revoked */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: false;
                        code: string;
                        status: number;
                        message: string;
                        data?: unknown;
                    };
                };
            };
            /** @description 404 */
            404: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "RECORD_NOT_FOUND";
                        /** @constant */
                        status: 404;
                        /** @default No message or reply on this thread has this sequence */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: false;
                        code: string;
                        status: number;
                        message: string;
                        data?: unknown;
                    };
                };
            };
            /** @description 409 */
            409: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "CLIENT_ACTION_ID_REUSED";
                        /** @constant */
                        status: 409;
                        /** @default The client action ID belongs to a different action */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: false;
                        code: string;
                        status: number;
                        message: string;
                        data?: unknown;
                    };
                };
            };
        };
    };
    "memory.readVersions": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        requestBody: {
            content: {
                "application/json": {
                    versions: {
                        itemID: string;
                        version: number;
                    }[];
                };
            };
        };
        responses: {
            /** @description OK */
            200: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        versions: {
                            itemID: string;
                            version: number;
                            /** @enum {string} */
                            status: "readable" | "shredded" | "unreadable" | "missing";
                            text?: string;
                        }[];
                    };
                };
            };
            /** @description 401 */
            401: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "UNAUTHORIZED";
                        /** @constant */
                        status: 401;
                        /** @default The device session is missing, lapsed or revoked */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: false;
                        code: string;
                        status: number;
                        message: string;
                        data?: unknown;
                    };
                };
            };
        };
    };
    "memory.readRatingNotes": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        requestBody: {
            content: {
                "application/json": {
                    notes: {
                        itemID: string;
                        sequence: number;
                    }[];
                };
            };
        };
        responses: {
            /** @description OK */
            200: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        notes: {
                            itemID: string;
                            sequence: number;
                            /** @enum {string} */
                            status: "readable" | "shredded" | "unreadable" | "missing";
                            text?: string;
                        }[];
                    };
                };
            };
            /** @description 401 */
            401: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "UNAUTHORIZED";
                        /** @constant */
                        status: 401;
                        /** @default The device session is missing, lapsed or revoked */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: false;
                        code: string;
                        status: number;
                        message: string;
                        data?: unknown;
                    };
                };
            };
        };
    };
    "memory.writerStatus": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        requestBody?: never;
        responses: {
            /** @description OK */
            200: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        isEnabled: boolean;
                        backlog: number;
                        batches: number;
                        cursor: number;
                        failures: number;
                        isCatchingUp: boolean;
                        lastError: {
                            /** Format: date-time */
                            at: string;
                            code: string;
                            message: string | null;
                        } | null;
                        retryAt: string | null;
                    };
                };
            };
            /** @description 401 */
            401: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "UNAUTHORIZED";
                        /** @constant */
                        status: 401;
                        /** @default The device session is missing, lapsed or revoked */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: false;
                        code: string;
                        status: number;
                        message: string;
                        data?: unknown;
                    };
                };
            };
        };
    };
    "memory.consolidatorStatus": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        requestBody?: never;
        responses: {
            /** @description OK */
            200: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        isEnabled: boolean;
                    };
                };
            };
            /** @description 401 */
            401: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "UNAUTHORIZED";
                        /** @constant */
                        status: 401;
                        /** @default The device session is missing, lapsed or revoked */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: false;
                        code: string;
                        status: number;
                        message: string;
                        data?: unknown;
                    };
                };
            };
        };
    };
    "memory.listItems": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        requestBody: {
            content: {
                "application/json": {
                    after?: string;
                    /** @enum {string} */
                    kind?: "fact" | "self";
                    limit?: number;
                    /** @enum {string} */
                    state: "active" | "retired" | "forgotten";
                };
            };
        };
        responses: {
            /** @description OK */
            200: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        items: {
                            /** Format: date-time */
                            changedAt: string;
                            /** Format: date-time */
                            createdAt: string;
                            forgottenAt: string | null;
                            isPinned: boolean;
                            isSensitive: boolean;
                            itemID: string;
                            /** @enum {string} */
                            kind: "fact" | "self";
                            /** @enum {string} */
                            origin: "owner" | "conversation" | "task" | "memory_writer" | "lapse";
                            shortID: string;
                            /** @enum {string} */
                            source: "owner" | "owner_data" | "untrusted";
                            /** @enum {string} */
                            state: "active" | "retired" | "forgetting" | "forgotten";
                            /** @enum {string} */
                            status: "readable" | "shredded" | "unreadable";
                            /** @enum {string} */
                            subject: "owner" | "self" | "shared";
                            text?: string;
                            until: string | null;
                            version: number;
                        }[];
                        next: string | null;
                    };
                };
            };
            /** @description 400 */
            400: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "INVALID_CURSOR";
                        /** @constant */
                        status: 400;
                        /** @default No page returned this cursor */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: false;
                        code: string;
                        status: number;
                        message: string;
                        data?: unknown;
                    };
                };
            };
            /** @description 401 */
            401: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "UNAUTHORIZED";
                        /** @constant */
                        status: 401;
                        /** @default The device session is missing, lapsed or revoked */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: false;
                        code: string;
                        status: number;
                        message: string;
                        data?: unknown;
                    };
                };
            };
            /** @description 503 */
            503: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "MEMORY_NOT_STARTED";
                        /** @constant */
                        status: 503;
                        /** @default The memory store has not started yet */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: false;
                        code: string;
                        status: number;
                        message: string;
                        data?: unknown;
                    };
                };
            };
        };
    };
    "memory.findItems": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        requestBody: {
            content: {
                "application/json": {
                    query: string;
                };
            };
        };
        responses: {
            /** @description OK */
            200: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        items: {
                            /** Format: date-time */
                            changedAt: string;
                            /** Format: date-time */
                            createdAt: string;
                            forgottenAt: string | null;
                            isPinned: boolean;
                            isSensitive: boolean;
                            itemID: string;
                            /** @enum {string} */
                            kind: "fact" | "self";
                            /** @enum {string} */
                            origin: "owner" | "conversation" | "task" | "memory_writer" | "lapse";
                            shortID: string;
                            /** @enum {string} */
                            source: "owner" | "owner_data" | "untrusted";
                            /** @enum {string} */
                            state: "active" | "retired" | "forgetting" | "forgotten";
                            /** @enum {string} */
                            status: "readable" | "shredded" | "unreadable";
                            /** @enum {string} */
                            subject: "owner" | "self" | "shared";
                            text?: string;
                            until: string | null;
                            version: number;
                            score?: number;
                            similarity?: number;
                        }[];
                        /** @enum {string} */
                        searchMode: "hybrid" | "keyword" | "keyword-fallback";
                    };
                };
            };
            /** @description 401 */
            401: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "UNAUTHORIZED";
                        /** @constant */
                        status: 401;
                        /** @default The device session is missing, lapsed or revoked */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: false;
                        code: string;
                        status: number;
                        message: string;
                        data?: unknown;
                    };
                };
            };
            /** @description 503 */
            503: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "MEMORY_NOT_STARTED";
                        /** @constant */
                        status: 503;
                        /** @default The memory store has not started yet */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: false;
                        code: string;
                        status: number;
                        message: string;
                        data?: unknown;
                    };
                };
            };
        };
    };
    "memory.readPinnedCore": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        requestBody?: never;
        responses: {
            /** @description OK */
            200: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        budget: number;
                        items: {
                            /** Format: date-time */
                            changedAt: string;
                            /** Format: date-time */
                            createdAt: string;
                            forgottenAt: string | null;
                            isPinned: boolean;
                            isSensitive: boolean;
                            itemID: string;
                            /** @enum {string} */
                            kind: "fact" | "self";
                            /** @enum {string} */
                            origin: "owner" | "conversation" | "task" | "memory_writer" | "lapse";
                            shortID: string;
                            /** @enum {string} */
                            source: "owner" | "owner_data" | "untrusted";
                            /** @enum {string} */
                            state: "active" | "retired" | "forgetting" | "forgotten";
                            /** @enum {string} */
                            status: "readable" | "shredded" | "unreadable";
                            /** @enum {string} */
                            subject: "owner" | "self" | "shared";
                            text?: string;
                            until: string | null;
                            version: number;
                        }[];
                        tokens: number;
                    };
                };
            };
            /** @description 401 */
            401: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "UNAUTHORIZED";
                        /** @constant */
                        status: 401;
                        /** @default The device session is missing, lapsed or revoked */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: false;
                        code: string;
                        status: number;
                        message: string;
                        data?: unknown;
                    };
                };
            };
            /** @description 503 */
            503: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "MEMORY_NOT_STARTED";
                        /** @constant */
                        status: 503;
                        /** @default The memory store has not started yet */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: false;
                        code: string;
                        status: number;
                        message: string;
                        data?: unknown;
                    };
                };
            };
        };
    };
    "memory.readItem": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        requestBody: {
            content: {
                "application/json": {
                    itemID: string;
                };
            };
        };
        responses: {
            /** @description OK */
            200: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** Format: date-time */
                        changedAt: string;
                        /** Format: date-time */
                        createdAt: string;
                        forgottenAt: string | null;
                        isPinned: boolean;
                        isSensitive: boolean;
                        itemID: string;
                        /** @enum {string} */
                        kind: "fact" | "self";
                        /** @enum {string} */
                        origin: "owner" | "conversation" | "task" | "memory_writer" | "lapse";
                        shortID: string;
                        /** @enum {string} */
                        source: "owner" | "owner_data" | "untrusted";
                        /** @enum {string} */
                        state: "active" | "retired" | "forgetting" | "forgotten";
                        /** @enum {string} */
                        status: "readable" | "shredded" | "unreadable";
                        /** @enum {string} */
                        subject: "owner" | "self" | "shared";
                        text?: string;
                        until: string | null;
                        version: number;
                        versions: {
                            /** @enum {string} */
                            change: "created" | "edited" | "retired" | "restored" | "undone";
                            checkerModel: string | null;
                            checks: {
                                [key: string]: unknown;
                            } | null;
                            evidence: {
                                end: number;
                                message: {
                                    /** @enum {string} */
                                    status: "readable" | "shredded" | "unreadable" | "missing";
                                    text?: string;
                                } | null;
                                sequence: number;
                                start: number;
                            } | null;
                            evidenceQuote: string | null;
                            /** @enum {string} */
                            origin: "owner" | "conversation" | "task" | "memory_writer" | "lapse";
                            proposalID: string | null;
                            /** Format: date-time */
                            recordedAt: string;
                            /** @enum {string} */
                            source: "owner" | "owner_data" | "untrusted";
                            /** @enum {string} */
                            state: "active" | "retired";
                            /** @enum {string} */
                            status: "readable" | "shredded" | "unreadable";
                            taskID: string | null;
                            text?: string;
                            version: number;
                            writerModel: string | null;
                        }[];
                    };
                };
            };
            /** @description 401 */
            401: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "UNAUTHORIZED";
                        /** @constant */
                        status: 401;
                        /** @default The device session is missing, lapsed or revoked */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: false;
                        code: string;
                        status: number;
                        message: string;
                        data?: unknown;
                    };
                };
            };
            /** @description 404 */
            404: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "MEMORY_ITEM_NOT_FOUND";
                        /** @constant */
                        status: 404;
                        /** @default No memory item has this ID */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: false;
                        code: string;
                        status: number;
                        message: string;
                        data?: unknown;
                    };
                };
            };
            /** @description 503 */
            503: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "MEMORY_NOT_STARTED";
                        /** @constant */
                        status: 503;
                        /** @default The memory store has not started yet */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: false;
                        code: string;
                        status: number;
                        message: string;
                        data?: unknown;
                    };
                };
            };
        };
    };
    "memory.retire": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        requestBody: {
            content: {
                "application/json": {
                    /** Format: uuid */
                    clientActionID: string;
                    itemID: string;
                    version: number;
                };
            };
        };
        responses: {
            /** @description OK */
            200: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        itemID: string;
                        version: number;
                    };
                };
            };
            /** @description 401 */
            401: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "UNAUTHORIZED";
                        /** @constant */
                        status: 401;
                        /** @default The device session is missing, lapsed or revoked */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: false;
                        code: string;
                        status: number;
                        message: string;
                        data?: unknown;
                    };
                };
            };
            /** @description 404 */
            404: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "MEMORY_ITEM_NOT_FOUND";
                        /** @constant */
                        status: 404;
                        /** @default No memory item has this ID */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: false;
                        code: string;
                        status: number;
                        message: string;
                        data?: unknown;
                    };
                };
            };
            /** @description 409 */
            409: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "CLIENT_ACTION_ID_REUSED";
                        /** @constant */
                        status: 409;
                        /** @default The client action ID belongs to a different action */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "STALE_VERSION";
                        /** @constant */
                        status: 409;
                        /** @default The memory item has moved past that version */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "WRONG_STATE";
                        /** @constant */
                        status: 409;
                        /** @default The memory item is not in a state that change takes */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: false;
                        code: string;
                        status: number;
                        message: string;
                        data?: unknown;
                    };
                };
            };
            /** @description 503 */
            503: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "MEMORY_NOT_STARTED";
                        /** @constant */
                        status: 503;
                        /** @default The memory store has not started yet */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: false;
                        code: string;
                        status: number;
                        message: string;
                        data?: unknown;
                    };
                };
            };
        };
    };
    "memory.restore": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        requestBody: {
            content: {
                "application/json": {
                    /** Format: uuid */
                    clientActionID: string;
                    itemID: string;
                    version: number;
                };
            };
        };
        responses: {
            /** @description OK */
            200: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        itemID: string;
                        version: number;
                    };
                };
            };
            /** @description 401 */
            401: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "UNAUTHORIZED";
                        /** @constant */
                        status: 401;
                        /** @default The device session is missing, lapsed or revoked */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: false;
                        code: string;
                        status: number;
                        message: string;
                        data?: unknown;
                    };
                };
            };
            /** @description 404 */
            404: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "MEMORY_ITEM_NOT_FOUND";
                        /** @constant */
                        status: 404;
                        /** @default No memory item has this ID */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: false;
                        code: string;
                        status: number;
                        message: string;
                        data?: unknown;
                    };
                };
            };
            /** @description 409 */
            409: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "CLIENT_ACTION_ID_REUSED";
                        /** @constant */
                        status: 409;
                        /** @default The client action ID belongs to a different action */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "STALE_VERSION";
                        /** @constant */
                        status: 409;
                        /** @default The memory item has moved past that version */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "WRONG_STATE";
                        /** @constant */
                        status: 409;
                        /** @default The memory item is not in a state that change takes */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: false;
                        code: string;
                        status: number;
                        message: string;
                        data?: unknown;
                    };
                };
            };
            /** @description 503 */
            503: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "MEMORY_NOT_STARTED";
                        /** @constant */
                        status: 503;
                        /** @default The memory store has not started yet */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: false;
                        code: string;
                        status: number;
                        message: string;
                        data?: unknown;
                    };
                };
            };
        };
    };
    "memory.listNotices": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        requestBody: {
            content: {
                "application/json": {
                    thread: string;
                };
            };
        };
        responses: {
            /** @description OK */
            200: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        notices: {
                            entries: {
                                /** @enum {string} */
                                change: "created" | "edited" | "retired" | "restored" | "undone" | "proposed";
                                isKept: boolean;
                                item: {
                                    /** Format: date-time */
                                    changedAt: string;
                                    /** Format: date-time */
                                    createdAt: string;
                                    forgottenAt: string | null;
                                    isPinned: boolean;
                                    isSensitive: boolean;
                                    itemID: string;
                                    /** @enum {string} */
                                    kind: "fact" | "self";
                                    /** @enum {string} */
                                    origin: "owner" | "conversation" | "task" | "memory_writer" | "lapse";
                                    shortID: string;
                                    /** @enum {string} */
                                    source: "owner" | "owner_data" | "untrusted";
                                    /** @enum {string} */
                                    state: "active" | "retired" | "forgetting" | "forgotten";
                                    /** @enum {string} */
                                    status: "readable" | "shredded" | "unreadable";
                                    /** @enum {string} */
                                    subject: "owner" | "self" | "shared";
                                    text?: string;
                                    until: string | null;
                                    version: number;
                                    /** @enum {string} */
                                    change: "created" | "edited" | "retired" | "restored" | "undone";
                                } | null;
                                itemID: string;
                                proposalID: string | null;
                                sequence: number;
                                version: number | null;
                            }[];
                            /** @enum {string} */
                            kind: "turn" | "batch" | "catch_up" | "run";
                            messageSequence: number | null;
                            noticeKey: string;
                            proposed: number;
                            remembered: number;
                            retired: number;
                            sequence: number;
                        }[];
                    };
                };
            };
            /** @description 401 */
            401: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "UNAUTHORIZED";
                        /** @constant */
                        status: 401;
                        /** @default The device session is missing, lapsed or revoked */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: false;
                        code: string;
                        status: number;
                        message: string;
                        data?: unknown;
                    };
                };
            };
            /** @description 503 */
            503: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "MEMORY_NOT_STARTED";
                        /** @constant */
                        status: 503;
                        /** @default The memory store has not started yet */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: false;
                        code: string;
                        status: number;
                        message: string;
                        data?: unknown;
                    };
                };
            };
        };
    };
    "memory.undo": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        requestBody: {
            content: {
                "application/json": {
                    /** Format: uuid */
                    clientActionID: string;
                    itemID: string;
                    version: number;
                };
            };
        };
        responses: {
            /** @description OK */
            200: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        itemID: string;
                        version: number;
                    };
                };
            };
            /** @description 401 */
            401: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "UNAUTHORIZED";
                        /** @constant */
                        status: 401;
                        /** @default The device session is missing, lapsed or revoked */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: false;
                        code: string;
                        status: number;
                        message: string;
                        data?: unknown;
                    };
                };
            };
            /** @description 404 */
            404: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "MEMORY_ITEM_NOT_FOUND";
                        /** @constant */
                        status: 404;
                        /** @default No memory item has this ID */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: false;
                        code: string;
                        status: number;
                        message: string;
                        data?: unknown;
                    };
                };
            };
            /** @description 409 */
            409: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "CLIENT_ACTION_ID_REUSED";
                        /** @constant */
                        status: 409;
                        /** @default The client action ID belongs to a different action */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "STALE_VERSION";
                        /** @constant */
                        status: 409;
                        /** @default The memory item has moved past that version */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "WRONG_STATE";
                        /** @constant */
                        status: 409;
                        /** @default The memory item is not in a state that change takes */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "PINNED_CORE_FULL";
                        /** @constant */
                        status: 409;
                        /** @default The undo takes the pinned core past its budget */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: false;
                        code: string;
                        status: number;
                        message: string;
                        data?: unknown;
                    };
                };
            };
            /** @description 503 */
            503: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "MEMORY_NOT_STARTED";
                        /** @constant */
                        status: 503;
                        /** @default The memory store has not started yet */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: false;
                        code: string;
                        status: number;
                        message: string;
                        data?: unknown;
                    };
                };
            };
        };
    };
    "memory.keep": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        requestBody: {
            content: {
                "application/json": {
                    /** Format: uuid */
                    clientActionID: string;
                    itemID: string;
                    version: number;
                };
            };
        };
        responses: {
            /** @description OK */
            200: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        itemID: string;
                        version: number;
                    };
                };
            };
            /** @description 401 */
            401: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "UNAUTHORIZED";
                        /** @constant */
                        status: 401;
                        /** @default The device session is missing, lapsed or revoked */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: false;
                        code: string;
                        status: number;
                        message: string;
                        data?: unknown;
                    };
                };
            };
            /** @description 404 */
            404: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "MEMORY_ITEM_NOT_FOUND";
                        /** @constant */
                        status: 404;
                        /** @default No memory item has this ID */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: false;
                        code: string;
                        status: number;
                        message: string;
                        data?: unknown;
                    };
                };
            };
            /** @description 409 */
            409: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "CLIENT_ACTION_ID_REUSED";
                        /** @constant */
                        status: 409;
                        /** @default The client action ID belongs to a different action */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "STALE_VERSION";
                        /** @constant */
                        status: 409;
                        /** @default The memory item has moved past that version */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "WRONG_STATE";
                        /** @constant */
                        status: 409;
                        /** @default The memory item is not in a state that change takes */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: false;
                        code: string;
                        status: number;
                        message: string;
                        data?: unknown;
                    };
                };
            };
            /** @description 503 */
            503: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "MEMORY_NOT_STARTED";
                        /** @constant */
                        status: 503;
                        /** @default The memory store has not started yet */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: false;
                        code: string;
                        status: number;
                        message: string;
                        data?: unknown;
                    };
                };
            };
        };
    };
    "memory.previewForget": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        requestBody: {
            content: {
                "application/json": {
                    itemID: string;
                    version: number;
                };
            };
        };
        responses: {
            /** @description OK */
            200: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** Format: date-time */
                        changedAt: string;
                        /** Format: date-time */
                        createdAt: string;
                        forgottenAt: string | null;
                        isPinned: boolean;
                        isSensitive: boolean;
                        itemID: string;
                        /** @enum {string} */
                        kind: "fact" | "self";
                        /** @enum {string} */
                        origin: "owner" | "conversation" | "task" | "memory_writer" | "lapse";
                        shortID: string;
                        /** @enum {string} */
                        source: "owner" | "owner_data" | "untrusted";
                        /** @enum {string} */
                        state: "active" | "retired" | "forgetting" | "forgotten";
                        /** @enum {string} */
                        status: "readable" | "shredded" | "unreadable";
                        /** @enum {string} */
                        subject: "owner" | "self" | "shared";
                        text?: string;
                        until: string | null;
                        version: number;
                        versions: {
                            /** @enum {string} */
                            change: "created" | "edited" | "retired" | "restored" | "undone";
                            checkerModel: string | null;
                            checks: {
                                [key: string]: unknown;
                            } | null;
                            evidence: {
                                end: number;
                                message: {
                                    /** @enum {string} */
                                    status: "readable" | "shredded" | "unreadable" | "missing";
                                    text?: string;
                                } | null;
                                sequence: number;
                                start: number;
                            } | null;
                            evidenceQuote: string | null;
                            /** @enum {string} */
                            origin: "owner" | "conversation" | "task" | "memory_writer" | "lapse";
                            proposalID: string | null;
                            /** Format: date-time */
                            recordedAt: string;
                            /** @enum {string} */
                            source: "owner" | "owner_data" | "untrusted";
                            /** @enum {string} */
                            state: "active" | "retired";
                            /** @enum {string} */
                            status: "readable" | "shredded" | "unreadable";
                            taskID: string | null;
                            text?: string;
                            version: number;
                            writerModel: string | null;
                        }[];
                        lost: {
                            evidenceMessages: number;
                            proposals: number;
                        };
                    };
                };
            };
            /** @description 401 */
            401: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "UNAUTHORIZED";
                        /** @constant */
                        status: 401;
                        /** @default The device session is missing, lapsed or revoked */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: false;
                        code: string;
                        status: number;
                        message: string;
                        data?: unknown;
                    };
                };
            };
            /** @description 404 */
            404: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "MEMORY_ITEM_NOT_FOUND";
                        /** @constant */
                        status: 404;
                        /** @default No memory item has this ID */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: false;
                        code: string;
                        status: number;
                        message: string;
                        data?: unknown;
                    };
                };
            };
            /** @description 409 */
            409: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "STALE_VERSION";
                        /** @constant */
                        status: 409;
                        /** @default The memory item has moved past that version */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: false;
                        code: string;
                        status: number;
                        message: string;
                        data?: unknown;
                    };
                };
            };
            /** @description 503 */
            503: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "MEMORY_NOT_STARTED";
                        /** @constant */
                        status: 503;
                        /** @default The memory store has not started yet */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: false;
                        code: string;
                        status: number;
                        message: string;
                        data?: unknown;
                    };
                };
            };
        };
    };
    "memory.forget": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        requestBody: {
            content: {
                "application/json": {
                    /** Format: uuid */
                    clientActionID: string;
                    itemID: string;
                    version: number;
                };
            };
        };
        responses: {
            /** @description OK */
            200: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        itemID: string;
                    };
                };
            };
            /** @description 401 */
            401: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "UNAUTHORIZED";
                        /** @constant */
                        status: 401;
                        /** @default The device session is missing, lapsed or revoked */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: false;
                        code: string;
                        status: number;
                        message: string;
                        data?: unknown;
                    };
                };
            };
            /** @description 404 */
            404: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "MEMORY_ITEM_NOT_FOUND";
                        /** @constant */
                        status: 404;
                        /** @default No memory item has this ID */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: false;
                        code: string;
                        status: number;
                        message: string;
                        data?: unknown;
                    };
                };
            };
            /** @description 409 */
            409: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "CLIENT_ACTION_ID_REUSED";
                        /** @constant */
                        status: 409;
                        /** @default The client action ID belongs to a different action */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "STALE_VERSION";
                        /** @constant */
                        status: 409;
                        /** @default The memory item has moved past that version */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "WRONG_STATE";
                        /** @constant */
                        status: 409;
                        /** @default The memory item is not in a state that change takes */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: false;
                        code: string;
                        status: number;
                        message: string;
                        data?: unknown;
                    };
                };
            };
            /** @description 503 */
            503: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "MEMORY_NOT_STARTED";
                        /** @constant */
                        status: 503;
                        /** @default The memory store has not started yet */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: false;
                        code: string;
                        status: number;
                        message: string;
                        data?: unknown;
                    };
                };
            };
        };
    };
    "memory.previewForgetRetired": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        requestBody?: never;
        responses: {
            /** @description OK */
            200: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        hasMore: boolean;
                        items: {
                            /** Format: date-time */
                            changedAt: string;
                            /** Format: date-time */
                            createdAt: string;
                            forgottenAt: string | null;
                            isPinned: boolean;
                            isSensitive: boolean;
                            itemID: string;
                            /** @enum {string} */
                            kind: "fact" | "self";
                            /** @enum {string} */
                            origin: "owner" | "conversation" | "task" | "memory_writer" | "lapse";
                            shortID: string;
                            /** @enum {string} */
                            source: "owner" | "owner_data" | "untrusted";
                            /** @enum {string} */
                            state: "active" | "retired" | "forgetting" | "forgotten";
                            /** @enum {string} */
                            status: "readable" | "shredded" | "unreadable";
                            /** @enum {string} */
                            subject: "owner" | "self" | "shared";
                            text?: string;
                            until: string | null;
                            version: number;
                            lost: {
                                evidenceMessages: number;
                                proposals: number;
                            };
                        }[];
                    };
                };
            };
            /** @description 401 */
            401: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "UNAUTHORIZED";
                        /** @constant */
                        status: 401;
                        /** @default The device session is missing, lapsed or revoked */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: false;
                        code: string;
                        status: number;
                        message: string;
                        data?: unknown;
                    };
                };
            };
            /** @description 503 */
            503: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "MEMORY_NOT_STARTED";
                        /** @constant */
                        status: 503;
                        /** @default The memory store has not started yet */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: false;
                        code: string;
                        status: number;
                        message: string;
                        data?: unknown;
                    };
                };
            };
        };
    };
    "memory.forgetRetired": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        requestBody: {
            content: {
                "application/json": {
                    /** Format: uuid */
                    clientActionID: string;
                    targets: {
                        itemID: string;
                        version: number;
                    }[];
                };
            };
        };
        responses: {
            /** @description OK */
            200: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        deleted: string[];
                        pending: string[];
                    };
                };
            };
            /** @description 401 */
            401: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "UNAUTHORIZED";
                        /** @constant */
                        status: 401;
                        /** @default The device session is missing, lapsed or revoked */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: false;
                        code: string;
                        status: number;
                        message: string;
                        data?: unknown;
                    };
                };
            };
            /** @description 404 */
            404: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "MEMORY_ITEM_NOT_FOUND";
                        /** @constant */
                        status: 404;
                        /** @default No memory item has this ID */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: false;
                        code: string;
                        status: number;
                        message: string;
                        data?: unknown;
                    };
                };
            };
            /** @description 409 */
            409: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "CLIENT_ACTION_ID_REUSED";
                        /** @constant */
                        status: 409;
                        /** @default The client action ID belongs to a different action */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "STALE_VERSION";
                        /** @constant */
                        status: 409;
                        /** @default The memory item has moved past that version */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "WRONG_STATE";
                        /** @constant */
                        status: 409;
                        /** @default The memory item is not in a state that change takes */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: false;
                        code: string;
                        status: number;
                        message: string;
                        data?: unknown;
                    };
                };
            };
            /** @description 503 */
            503: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "MEMORY_NOT_STARTED";
                        /** @constant */
                        status: 503;
                        /** @default The memory store has not started yet */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: false;
                        code: string;
                        status: number;
                        message: string;
                        data?: unknown;
                    };
                };
            };
        };
    };
    "memory.readForgetStatus": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        requestBody: {
            content: {
                "application/json": {
                    itemIDs: string[];
                };
            };
        };
        responses: {
            /** @description OK */
            200: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        deleted: string[];
                        pending: string[];
                    };
                };
            };
            /** @description 401 */
            401: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "UNAUTHORIZED";
                        /** @constant */
                        status: 401;
                        /** @default The device session is missing, lapsed or revoked */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: false;
                        code: string;
                        status: number;
                        message: string;
                        data?: unknown;
                    };
                };
            };
            /** @description 503 */
            503: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "MEMORY_NOT_STARTED";
                        /** @constant */
                        status: 503;
                        /** @default The memory store has not started yet */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: false;
                        code: string;
                        status: number;
                        message: string;
                        data?: unknown;
                    };
                };
            };
        };
    };
    "memory.pin": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        requestBody: {
            content: {
                "application/json": {
                    /** Format: uuid */
                    clientActionID: string;
                    itemID: string;
                    version: number;
                    isPinned: boolean;
                };
            };
        };
        responses: {
            /** @description OK */
            200: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        isPinned: boolean;
                        itemID: string;
                    };
                };
            };
            /** @description 401 */
            401: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "UNAUTHORIZED";
                        /** @constant */
                        status: 401;
                        /** @default The device session is missing, lapsed or revoked */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: false;
                        code: string;
                        status: number;
                        message: string;
                        data?: unknown;
                    };
                };
            };
            /** @description 404 */
            404: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "MEMORY_ITEM_NOT_FOUND";
                        /** @constant */
                        status: 404;
                        /** @default No memory item has this ID */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: false;
                        code: string;
                        status: number;
                        message: string;
                        data?: unknown;
                    };
                };
            };
            /** @description 409 */
            409: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "CLIENT_ACTION_ID_REUSED";
                        /** @constant */
                        status: 409;
                        /** @default The client action ID belongs to a different action */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "STALE_VERSION";
                        /** @constant */
                        status: 409;
                        /** @default The memory item has moved past that version */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "WRONG_STATE";
                        /** @constant */
                        status: 409;
                        /** @default The memory item is not in a state that change takes */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "PINNED_CORE_FULL";
                        /** @constant */
                        status: 409;
                        /** @default The pin takes the pinned core past its budget */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: false;
                        code: string;
                        status: number;
                        message: string;
                        data?: unknown;
                    };
                };
            };
            /** @description 503 */
            503: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "MEMORY_NOT_STARTED";
                        /** @constant */
                        status: 503;
                        /** @default The memory store has not started yet */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: false;
                        code: string;
                        status: number;
                        message: string;
                        data?: unknown;
                    };
                };
            };
        };
    };
    "memory.markSensitive": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        requestBody: {
            content: {
                "application/json": {
                    /** Format: uuid */
                    clientActionID: string;
                    isSensitive: boolean;
                    itemID: string;
                };
            };
        };
        responses: {
            /** @description OK */
            200: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        isSensitive: boolean;
                        itemID: string;
                    };
                };
            };
            /** @description 401 */
            401: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "UNAUTHORIZED";
                        /** @constant */
                        status: 401;
                        /** @default The device session is missing, lapsed or revoked */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: false;
                        code: string;
                        status: number;
                        message: string;
                        data?: unknown;
                    };
                };
            };
            /** @description 404 */
            404: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "MEMORY_ITEM_NOT_FOUND";
                        /** @constant */
                        status: 404;
                        /** @default No memory item has this ID */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: false;
                        code: string;
                        status: number;
                        message: string;
                        data?: unknown;
                    };
                };
            };
            /** @description 409 */
            409: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "CLIENT_ACTION_ID_REUSED";
                        /** @constant */
                        status: 409;
                        /** @default The client action ID belongs to a different action */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "STALE_VERSION";
                        /** @constant */
                        status: 409;
                        /** @default The memory item has moved past that version */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "WRONG_STATE";
                        /** @constant */
                        status: 409;
                        /** @default The memory item is not in a state that change takes */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: false;
                        code: string;
                        status: number;
                        message: string;
                        data?: unknown;
                    };
                };
            };
            /** @description 503 */
            503: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "MEMORY_NOT_STARTED";
                        /** @constant */
                        status: 503;
                        /** @default The memory store has not started yet */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: false;
                        code: string;
                        status: number;
                        message: string;
                        data?: unknown;
                    };
                };
            };
        };
    };
    "memory.listProposals": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        requestBody?: never;
        responses: {
            /** @description OK */
            200: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        proposals: {
                            actionHash: string;
                            /** Format: date-time */
                            createdAt: string;
                            evidence: {
                                end: number;
                                message: {
                                    /** @enum {string} */
                                    status: "readable" | "shredded" | "unreadable" | "missing";
                                    text?: string;
                                } | null;
                                sequence: number;
                                start: number;
                            } | null;
                            image: {
                                position: number;
                                sequence: number;
                                thread: string;
                            } | null;
                            isPinned: boolean;
                            isSensitive: boolean;
                            itemID: string;
                            /** @enum {string} */
                            kind: "fact" | "self";
                            /** Format: date-time */
                            lapseAt: string;
                            /** @enum {string} */
                            operation: "remember" | "retire" | "pin";
                            /** @enum {string} */
                            origin: "owner" | "conversation" | "task" | "memory_writer";
                            proposalID: string;
                            quote: string | null;
                            /** @enum {string} */
                            reason: "no_quote" | "quote_not_typed" | "quote_in_quoted_block" | "invisible_character" | "token_missing" | "checker_not_asserted" | "checker_unsure" | "checker_unreachable" | "forgotten_evidence" | "ambiguous_target" | "pinned" | "other" | "self_note" | "from_photo" | "sensitive";
                            /** @enum {string} */
                            source: "owner" | "owner_data" | "untrusted";
                            sources: {
                                /** @enum {string} */
                                origin: "owner" | "conversation" | "task" | "memory_writer";
                                /** Format: date-time */
                                proposedAt: string;
                                thread: string | null;
                            }[];
                            /** @enum {string} */
                            subject: "owner" | "self" | "shared";
                            targetVersion: number | null;
                            text: string;
                            until: string | null;
                        }[];
                    };
                };
            };
            /** @description 401 */
            401: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "UNAUTHORIZED";
                        /** @constant */
                        status: 401;
                        /** @default The device session is missing, lapsed or revoked */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: false;
                        code: string;
                        status: number;
                        message: string;
                        data?: unknown;
                    };
                };
            };
            /** @description 503 */
            503: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "MEMORY_NOT_STARTED";
                        /** @constant */
                        status: 503;
                        /** @default The memory store has not started yet */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: false;
                        code: string;
                        status: number;
                        message: string;
                        data?: unknown;
                    };
                };
            };
        };
    };
    "memory.approveProposals": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        requestBody: {
            content: {
                "application/json": {
                    answers: {
                        actionHash: string;
                        /** Format: uuid */
                        clientActionID: string;
                        proposalID: string;
                        editedText?: string;
                        ignoreCloseMatch?: boolean;
                        revisionOf?: {
                            itemID: string;
                            version: number;
                        };
                    }[];
                };
            };
        };
        responses: {
            /** @description OK */
            200: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        outcomes: ({
                            proposalID: string;
                            /** @constant */
                            status: "applied";
                        } | {
                            proposalID: string;
                            /** @constant */
                            status: "rejected";
                        } | {
                            item: {
                                itemID: string;
                                text: string;
                                version: number;
                            };
                            proposalID: string;
                            /** @constant */
                            status: "close_match";
                        } | {
                            /** @enum {string} */
                            cause: "lapsed" | "answered" | "moved" | "changed" | "gone";
                            proposalID: string;
                            /** @constant */
                            status: "stale";
                        } | {
                            /** @enum {string} */
                            code: "CLIENT_ACTION_ID_REUSED" | "PIN_EDIT" | "PINNED_CORE_FULL" | "RETIREMENT_EDIT" | "REVISION_TARGET" | "WRONG_STATE";
                            proposalID: string;
                            /** @constant */
                            status: "refused";
                        })[];
                    };
                };
            };
            /** @description 401 */
            401: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "UNAUTHORIZED";
                        /** @constant */
                        status: 401;
                        /** @default The device session is missing, lapsed or revoked */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: false;
                        code: string;
                        status: number;
                        message: string;
                        data?: unknown;
                    };
                };
            };
            /** @description 503 */
            503: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "MEMORY_NOT_STARTED";
                        /** @constant */
                        status: 503;
                        /** @default The memory store has not started yet */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: false;
                        code: string;
                        status: number;
                        message: string;
                        data?: unknown;
                    };
                };
            };
        };
    };
    "memory.rejectProposals": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        requestBody: {
            content: {
                "application/json": {
                    answers: {
                        actionHash: string;
                        /** Format: uuid */
                        clientActionID: string;
                        proposalID: string;
                        reason?: string;
                    }[];
                };
            };
        };
        responses: {
            /** @description OK */
            200: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        outcomes: ({
                            proposalID: string;
                            /** @constant */
                            status: "applied";
                        } | {
                            proposalID: string;
                            /** @constant */
                            status: "rejected";
                        } | {
                            item: {
                                itemID: string;
                                text: string;
                                version: number;
                            };
                            proposalID: string;
                            /** @constant */
                            status: "close_match";
                        } | {
                            /** @enum {string} */
                            cause: "lapsed" | "answered" | "moved" | "changed" | "gone";
                            proposalID: string;
                            /** @constant */
                            status: "stale";
                        } | {
                            /** @enum {string} */
                            code: "CLIENT_ACTION_ID_REUSED" | "PIN_EDIT" | "PINNED_CORE_FULL" | "RETIREMENT_EDIT" | "REVISION_TARGET" | "WRONG_STATE";
                            proposalID: string;
                            /** @constant */
                            status: "refused";
                        })[];
                    };
                };
            };
            /** @description 401 */
            401: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "UNAUTHORIZED";
                        /** @constant */
                        status: 401;
                        /** @default The device session is missing, lapsed or revoked */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: false;
                        code: string;
                        status: number;
                        message: string;
                        data?: unknown;
                    };
                };
            };
            /** @description 503 */
            503: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "MEMORY_NOT_STARTED";
                        /** @constant */
                        status: 503;
                        /** @default The memory store has not started yet */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: false;
                        code: string;
                        status: number;
                        message: string;
                        data?: unknown;
                    };
                };
            };
        };
    };
    "memory.export": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        requestBody: {
            content: {
                "application/json": {
                    /** Format: uuid */
                    clientActionID: string;
                };
            };
        };
        responses: {
            /** @description OK */
            200: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "text/event-stream": {
                        /** @constant */
                        event: "message";
                        data: {
                            chunk: string;
                        } | {
                            /** @constant */
                            isComplete: true;
                        };
                        id?: string;
                        retry?: number;
                    } | {
                        /** @constant */
                        event: "done";
                        data?: unknown;
                        id?: string;
                        retry?: number;
                    } | {
                        /** @constant */
                        event: "error";
                        data?: unknown;
                        id?: string;
                        retry?: number;
                    };
                };
            };
            /** @description 401 */
            401: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "UNAUTHORIZED";
                        /** @constant */
                        status: 401;
                        /** @default The device session is missing, lapsed or revoked */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: false;
                        code: string;
                        status: number;
                        message: string;
                        data?: unknown;
                    };
                };
            };
            /** @description 409 */
            409: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "CLIENT_ACTION_ID_REUSED";
                        /** @constant */
                        status: 409;
                        /** @default The client action ID belongs to a different action */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: false;
                        code: string;
                        status: number;
                        message: string;
                        data?: unknown;
                    };
                };
            };
            /** @description 503 */
            503: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "MEMORY_NOT_STARTED";
                        /** @constant */
                        status: 503;
                        /** @default The memory store has not started yet */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: false;
                        code: string;
                        status: number;
                        message: string;
                        data?: unknown;
                    };
                };
            };
        };
    };
    "memory.keepMoment": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        requestBody: {
            content: {
                "application/json": {
                    /** Format: uuid */
                    clientActionID: string;
                    firstSequence: number;
                    lastSequence: number;
                    thread: string;
                    title: string;
                };
            };
        };
        responses: {
            /** @description OK */
            200: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        momentID: string;
                        shortID: string;
                    };
                };
            };
            /** @description 401 */
            401: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "UNAUTHORIZED";
                        /** @constant */
                        status: 401;
                        /** @default The device session is missing, lapsed or revoked */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: false;
                        code: string;
                        status: number;
                        message: string;
                        data?: unknown;
                    };
                };
            };
            /** @description 409 */
            409: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "CLIENT_ACTION_ID_REUSED";
                        /** @constant */
                        status: 409;
                        /** @default The client action ID belongs to a different action */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: false;
                        code: string;
                        status: number;
                        message: string;
                        data?: unknown;
                    };
                };
            };
            /** @description 422 */
            422: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "BAD_SPAN";
                        /** @constant */
                        status: 422;
                        /** @default The span needs a first and a last record on the thread, in order */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: false;
                        code: string;
                        status: number;
                        message: string;
                        data?: unknown;
                    };
                };
            };
            /** @description 503 */
            503: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "MEMORY_NOT_STARTED";
                        /** @constant */
                        status: 503;
                        /** @default The memory store has not started yet */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: false;
                        code: string;
                        status: number;
                        message: string;
                        data?: unknown;
                    };
                };
            };
        };
    };
    "memory.listMoments": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        requestBody: {
            content: {
                "application/json": {
                    before?: number;
                    includeRetired: boolean;
                    query?: string;
                };
            };
        };
        responses: {
            /** @description OK */
            200: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        moments: {
                            editedAt: string | null;
                            /** Format: date-time */
                            keptAt: string;
                            /** @enum {string} */
                            keptBy: "owner" | "model";
                            momentID: string;
                            shortID: string;
                            /** @enum {string} */
                            state: "active" | "retired";
                            title: string | null;
                        }[];
                        next: number | null;
                    };
                };
            };
            /** @description 401 */
            401: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "UNAUTHORIZED";
                        /** @constant */
                        status: 401;
                        /** @default The device session is missing, lapsed or revoked */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: false;
                        code: string;
                        status: number;
                        message: string;
                        data?: unknown;
                    };
                };
            };
            /** @description 503 */
            503: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "MEMORY_NOT_STARTED";
                        /** @constant */
                        status: 503;
                        /** @default The memory store has not started yet */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: false;
                        code: string;
                        status: number;
                        message: string;
                        data?: unknown;
                    };
                };
            };
        };
    };
    "memory.readMoment": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        requestBody: {
            content: {
                "application/json": {
                    momentID: string;
                };
            };
        };
        responses: {
            /** @description OK */
            200: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        editedAt: string | null;
                        /** Format: date-time */
                        keptAt: string;
                        /** @enum {string} */
                        keptBy: "owner" | "model";
                        momentID: string;
                        shortID: string;
                        /** @enum {string} */
                        state: "active" | "retired";
                        title: string | null;
                        firstSequence: number;
                        lastSequence: number;
                        links: {
                            itemID: string;
                            shortID: string;
                            text: string | null;
                        }[];
                        note: {
                            text: string;
                            /** Format: date-time */
                            writtenAt: string;
                        } | null;
                        reflections: {
                            model: string;
                            text: string | null;
                            /** Format: date-time */
                            writtenAt: string;
                            reflectionID: string;
                        }[];
                        thread: string;
                        /** @enum {string} */
                        titleBy: "owner" | "model";
                        version: number;
                    };
                };
            };
            /** @description 401 */
            401: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "UNAUTHORIZED";
                        /** @constant */
                        status: 401;
                        /** @default The device session is missing, lapsed or revoked */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: false;
                        code: string;
                        status: number;
                        message: string;
                        data?: unknown;
                    };
                };
            };
            /** @description 404 */
            404: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "MOMENT_NOT_FOUND";
                        /** @constant */
                        status: 404;
                        /** @default No moment has this ID */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: false;
                        code: string;
                        status: number;
                        message: string;
                        data?: unknown;
                    };
                };
            };
            /** @description 409 */
            409: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "STALE_VERSION";
                        /** @constant */
                        status: 409;
                        /** @default The moment has moved past that version */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: false;
                        code: string;
                        status: number;
                        message: string;
                        data?: unknown;
                    };
                };
            };
            /** @description 503 */
            503: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "MEMORY_NOT_STARTED";
                        /** @constant */
                        status: 503;
                        /** @default The memory store has not started yet */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: false;
                        code: string;
                        status: number;
                        message: string;
                        data?: unknown;
                    };
                };
            };
        };
    };
    "memory.readMomentSpan": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        requestBody: {
            content: {
                "application/json": {
                    momentID: string;
                    after?: number;
                };
            };
        };
        responses: {
            /** @description OK */
            200: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        records: {
                            isGap: boolean;
                            kind: string;
                            /** Format: date-time */
                            recordedAt: string;
                            sequence: number;
                            text: string | null;
                            tool: string | null;
                        }[];
                        next: number | null;
                    };
                };
            };
            /** @description 401 */
            401: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "UNAUTHORIZED";
                        /** @constant */
                        status: 401;
                        /** @default The device session is missing, lapsed or revoked */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: false;
                        code: string;
                        status: number;
                        message: string;
                        data?: unknown;
                    };
                };
            };
            /** @description 404 */
            404: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "MOMENT_NOT_FOUND";
                        /** @constant */
                        status: 404;
                        /** @default No moment has this ID */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: false;
                        code: string;
                        status: number;
                        message: string;
                        data?: unknown;
                    };
                };
            };
            /** @description 409 */
            409: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "STALE_VERSION";
                        /** @constant */
                        status: 409;
                        /** @default The moment has moved past that version */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: false;
                        code: string;
                        status: number;
                        message: string;
                        data?: unknown;
                    };
                };
            };
            /** @description 503 */
            503: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "MEMORY_NOT_STARTED";
                        /** @constant */
                        status: 503;
                        /** @default The memory store has not started yet */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: false;
                        code: string;
                        status: number;
                        message: string;
                        data?: unknown;
                    };
                };
            };
        };
    };
    "memory.editMoment": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        requestBody: {
            content: {
                "application/json": {
                    momentID: string;
                    version: number;
                    /** Format: uuid */
                    clientActionID: string;
                    change: {
                        /** @constant */
                        kind: "title";
                        title: string;
                    } | {
                        /** @constant */
                        kind: "edges";
                        firstSequence: number;
                        lastSequence: number;
                    } | {
                        /** @constant */
                        kind: "note";
                        note: string;
                    } | {
                        /** @constant */
                        kind: "reflection_removed";
                        reflectionID: string;
                    };
                };
            };
        };
        responses: {
            /** @description OK */
            200: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        momentID: string;
                        version: number;
                    };
                };
            };
            /** @description 401 */
            401: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "UNAUTHORIZED";
                        /** @constant */
                        status: 401;
                        /** @default The device session is missing, lapsed or revoked */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: false;
                        code: string;
                        status: number;
                        message: string;
                        data?: unknown;
                    };
                };
            };
            /** @description 404 */
            404: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "MOMENT_NOT_FOUND";
                        /** @constant */
                        status: 404;
                        /** @default No moment has this ID */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "REFLECTION_NOT_FOUND";
                        /** @constant */
                        status: 404;
                        /** @default The moment has no reflection with this ID */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: false;
                        code: string;
                        status: number;
                        message: string;
                        data?: unknown;
                    };
                };
            };
            /** @description 409 */
            409: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "STALE_VERSION";
                        /** @constant */
                        status: 409;
                        /** @default The moment has moved past that version */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "CLIENT_ACTION_ID_REUSED";
                        /** @constant */
                        status: 409;
                        /** @default The client action ID belongs to a different action */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: false;
                        code: string;
                        status: number;
                        message: string;
                        data?: unknown;
                    };
                };
            };
            /** @description 422 */
            422: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "BAD_SPAN";
                        /** @constant */
                        status: 422;
                        /** @default The span needs a first and a last record on the thread, in order */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: false;
                        code: string;
                        status: number;
                        message: string;
                        data?: unknown;
                    };
                };
            };
            /** @description 503 */
            503: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "MEMORY_NOT_STARTED";
                        /** @constant */
                        status: 503;
                        /** @default The memory store has not started yet */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: false;
                        code: string;
                        status: number;
                        message: string;
                        data?: unknown;
                    };
                };
            };
        };
    };
    "memory.linkMoment": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        requestBody: {
            content: {
                "application/json": {
                    momentID: string;
                    version: number;
                    /** Format: uuid */
                    clientActionID: string;
                    isLinked: boolean;
                    itemID: string;
                };
            };
        };
        responses: {
            /** @description OK */
            200: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        momentID: string;
                        version: number;
                    };
                };
            };
            /** @description 401 */
            401: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "UNAUTHORIZED";
                        /** @constant */
                        status: 401;
                        /** @default The device session is missing, lapsed or revoked */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: false;
                        code: string;
                        status: number;
                        message: string;
                        data?: unknown;
                    };
                };
            };
            /** @description 404 */
            404: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "MOMENT_NOT_FOUND";
                        /** @constant */
                        status: 404;
                        /** @default No moment has this ID */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "MEMORY_ITEM_NOT_FOUND";
                        /** @constant */
                        status: 404;
                        /** @default No memory item has this ID */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: false;
                        code: string;
                        status: number;
                        message: string;
                        data?: unknown;
                    };
                };
            };
            /** @description 409 */
            409: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "STALE_VERSION";
                        /** @constant */
                        status: 409;
                        /** @default The moment has moved past that version */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "CLIENT_ACTION_ID_REUSED";
                        /** @constant */
                        status: 409;
                        /** @default The client action ID belongs to a different action */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "ALREADY_LINKED";
                        /** @constant */
                        status: 409;
                        /** @default The item is already linked to the moment */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "NOT_LINKED";
                        /** @constant */
                        status: 409;
                        /** @default The item is not linked to the moment */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: false;
                        code: string;
                        status: number;
                        message: string;
                        data?: unknown;
                    };
                };
            };
            /** @description 503 */
            503: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "MEMORY_NOT_STARTED";
                        /** @constant */
                        status: 503;
                        /** @default The memory store has not started yet */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: false;
                        code: string;
                        status: number;
                        message: string;
                        data?: unknown;
                    };
                };
            };
        };
    };
    "memory.previewMomentDestroy": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        requestBody: {
            content: {
                "application/json": {
                    momentID: string;
                    version: number;
                };
            };
        };
        responses: {
            /** @description OK */
            200: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** Format: date-time */
                        keptAt: string;
                        /** @enum {string} */
                        keptBy: "owner" | "model";
                        kept: {
                            records: number;
                        };
                        lost: {
                            links: number;
                            texts: number;
                        };
                        momentID: string;
                        note: string | null;
                        reflections: {
                            model: string;
                            text: string | null;
                            /** Format: date-time */
                            writtenAt: string;
                        }[];
                        shortID: string;
                        /** @enum {string} */
                        state: "active" | "retired";
                        thread: string;
                        title: string | null;
                        version: number;
                    };
                };
            };
            /** @description 401 */
            401: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "UNAUTHORIZED";
                        /** @constant */
                        status: 401;
                        /** @default The device session is missing, lapsed or revoked */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: false;
                        code: string;
                        status: number;
                        message: string;
                        data?: unknown;
                    };
                };
            };
            /** @description 404 */
            404: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "MOMENT_NOT_FOUND";
                        /** @constant */
                        status: 404;
                        /** @default No moment has this ID */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: false;
                        code: string;
                        status: number;
                        message: string;
                        data?: unknown;
                    };
                };
            };
            /** @description 409 */
            409: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "STALE_VERSION";
                        /** @constant */
                        status: 409;
                        /** @default The moment has moved past that version */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: false;
                        code: string;
                        status: number;
                        message: string;
                        data?: unknown;
                    };
                };
            };
            /** @description 503 */
            503: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "MEMORY_NOT_STARTED";
                        /** @constant */
                        status: 503;
                        /** @default The memory store has not started yet */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: false;
                        code: string;
                        status: number;
                        message: string;
                        data?: unknown;
                    };
                };
            };
        };
    };
    "memory.destroyMoment": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        requestBody: {
            content: {
                "application/json": {
                    momentID: string;
                    version: number;
                    /** Format: uuid */
                    clientActionID: string;
                };
            };
        };
        responses: {
            /** @description OK */
            200: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        momentID: string;
                    };
                };
            };
            /** @description 401 */
            401: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "UNAUTHORIZED";
                        /** @constant */
                        status: 401;
                        /** @default The device session is missing, lapsed or revoked */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: false;
                        code: string;
                        status: number;
                        message: string;
                        data?: unknown;
                    };
                };
            };
            /** @description 404 */
            404: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "MOMENT_NOT_FOUND";
                        /** @constant */
                        status: 404;
                        /** @default No moment has this ID */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: false;
                        code: string;
                        status: number;
                        message: string;
                        data?: unknown;
                    };
                };
            };
            /** @description 409 */
            409: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "STALE_VERSION";
                        /** @constant */
                        status: 409;
                        /** @default The moment has moved past that version */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "CLIENT_ACTION_ID_REUSED";
                        /** @constant */
                        status: 409;
                        /** @default The client action ID belongs to a different action */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: false;
                        code: string;
                        status: number;
                        message: string;
                        data?: unknown;
                    };
                };
            };
            /** @description 503 */
            503: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "MEMORY_NOT_STARTED";
                        /** @constant */
                        status: 503;
                        /** @default The memory store has not started yet */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: false;
                        code: string;
                        status: number;
                        message: string;
                        data?: unknown;
                    };
                };
            };
        };
    };
    "log.follow": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        requestBody: {
            content: {
                "application/json": {
                    afterSequence: number;
                    thread?: string;
                };
            };
        };
        responses: {
            /** @description OK */
            200: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "text/event-stream": {
                        /** @constant */
                        event: "message";
                        data: {
                            record: {
                                compaction?: {
                                    postTokens?: number;
                                    preTokens: number;
                                    /** @enum {string} */
                                    trigger: "manual" | "auto";
                                };
                                compactionFailure?: {
                                    failures: number;
                                };
                                forget?: {
                                    sequence: number;
                                };
                                context?: {
                                    size: number;
                                    window: number;
                                };
                                kind: string;
                                message?: {
                                    /** Format: uuid */
                                    clientMessageId?: string;
                                    images?: {
                                        /** @enum {string} */
                                        mediaType: "image/jpeg" | "image/png" | "image/webp" | "image/gif";
                                    }[];
                                    spans?: {
                                        end: number;
                                        /** @enum {string} */
                                        source: "typed" | "pasted" | "dropped" | "unknown";
                                        start: number;
                                    }[];
                                    text: string;
                                };
                                moment?: {
                                    momentID: string;
                                    shortID: string;
                                    title?: string;
                                };
                                rating?: {
                                    items: {
                                        itemID: string;
                                        version: number;
                                        hasNote: boolean;
                                        /** @enum {string} */
                                        verdict: "helpful" | "noise" | "misleading";
                                    }[];
                                    ratedBy?: string;
                                    recalledSequence: number;
                                };
                                recall?: {
                                    items: {
                                        itemID: string;
                                        version: number;
                                        score?: number;
                                    }[];
                                };
                                /** Format: date-time */
                                recordedAt: string;
                                sequence: number;
                                summary?: {
                                    contextSize?: number;
                                    summaryTokens: number;
                                    text?: string;
                                    /** @enum {string} */
                                    trigger: "threshold" | "overflow";
                                };
                                thread: string;
                                task?: {
                                    error?: string;
                                    errorLimit?: number;
                                    errors?: number;
                                    /** Format: date-time */
                                    retryAt?: string;
                                    stepKey?: string;
                                    taskID: string;
                                };
                                toolCall?: {
                                    callID: string;
                                    content?: {
                                        [key: string]: unknown;
                                    };
                                    input?: {
                                        [key: string]: unknown;
                                    };
                                    outcome?: string;
                                    tool?: string;
                                };
                            };
                        };
                        id?: string;
                        retry?: number;
                    } | {
                        /** @constant */
                        event: "done";
                        data?: unknown;
                        id?: string;
                        retry?: number;
                    } | {
                        /** @constant */
                        event: "error";
                        data?: unknown;
                        id?: string;
                        retry?: number;
                    };
                };
            };
            /** @description 401 */
            401: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "UNAUTHORIZED";
                        /** @constant */
                        status: 401;
                        /** @default The device session is missing, lapsed or revoked */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: false;
                        code: string;
                        status: number;
                        message: string;
                        data?: unknown;
                    };
                };
            };
        };
    };
    "records.follow": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        requestBody: {
            content: {
                "application/json": {
                    afterSequence: number;
                    thread?: string;
                };
            };
        };
        responses: {
            /** @description OK */
            200: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "text/event-stream": {
                        /** @constant */
                        event: "message";
                        data: {
                            record: {
                                compaction?: {
                                    postTokens?: number;
                                    preTokens: number;
                                    /** @enum {string} */
                                    trigger: "manual" | "auto";
                                };
                                compactionFailure?: {
                                    failures: number;
                                };
                                forget?: {
                                    sequence: number;
                                };
                                context?: {
                                    size: number;
                                    window: number;
                                };
                                kind: string;
                                message?: {
                                    /** Format: uuid */
                                    clientMessageId?: string;
                                    images?: {
                                        /** @enum {string} */
                                        mediaType: "image/jpeg" | "image/png" | "image/webp" | "image/gif";
                                    }[];
                                    spans?: {
                                        end: number;
                                        /** @enum {string} */
                                        source: "typed" | "pasted" | "dropped" | "unknown";
                                        start: number;
                                    }[];
                                    text: string;
                                };
                                moment?: {
                                    momentID: string;
                                    shortID: string;
                                    title?: string;
                                };
                                rating?: {
                                    items: {
                                        itemID: string;
                                        version: number;
                                        hasNote: boolean;
                                        /** @enum {string} */
                                        verdict: "helpful" | "noise" | "misleading";
                                    }[];
                                    ratedBy?: string;
                                    recalledSequence: number;
                                };
                                recall?: {
                                    items: {
                                        itemID: string;
                                        version: number;
                                        score?: number;
                                    }[];
                                };
                                /** Format: date-time */
                                recordedAt: string;
                                sequence: number;
                                summary?: {
                                    contextSize?: number;
                                    summaryTokens: number;
                                    text?: string;
                                    /** @enum {string} */
                                    trigger: "threshold" | "overflow";
                                };
                                thread: string;
                                task?: {
                                    error?: string;
                                    errorLimit?: number;
                                    errors?: number;
                                    /** Format: date-time */
                                    retryAt?: string;
                                    stepKey?: string;
                                    taskID: string;
                                };
                                toolCall?: {
                                    callID: string;
                                    content?: {
                                        [key: string]: unknown;
                                    };
                                    input?: {
                                        [key: string]: unknown;
                                    };
                                    outcome?: string;
                                    tool?: string;
                                };
                            };
                        };
                        id?: string;
                        retry?: number;
                    } | {
                        /** @constant */
                        event: "done";
                        data?: unknown;
                        id?: string;
                        retry?: number;
                    } | {
                        /** @constant */
                        event: "error";
                        data?: unknown;
                        id?: string;
                        retry?: number;
                    };
                };
            };
            /** @description 401 */
            401: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "UNAUTHORIZED";
                        /** @constant */
                        status: 401;
                        /** @default The device session is missing, lapsed or revoked */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: false;
                        code: string;
                        status: number;
                        message: string;
                        data?: unknown;
                    };
                };
            };
        };
    };
    "sessions.enrol": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        requestBody: {
            content: {
                "application/json": {
                    /** Format: uuid */
                    clientActionID: string;
                    code: string;
                    deviceName: string;
                    /** @enum {string} */
                    tokenDelivery: "cookie" | "bearer";
                };
            };
        };
        responses: {
            /** @description OK */
            200: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** Format: uuid */
                        sessionID: string;
                        token?: string;
                    };
                };
            };
            /** @description 400 */
            400: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "ENROLMENT_CODE_INVALID";
                        /** @constant */
                        status: 400;
                        /** @default The enrolment code is unknown, used or lapsed */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: false;
                        code: string;
                        status: number;
                        message: string;
                        data?: unknown;
                    };
                };
            };
            /** @description 409 */
            409: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "CLIENT_ACTION_ID_REUSED";
                        /** @constant */
                        status: 409;
                        /** @default The client action ID belongs to a different action */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: false;
                        code: string;
                        status: number;
                        message: string;
                        data?: unknown;
                    };
                };
            };
        };
    };
    "sessions.issueCode": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        requestBody: {
            content: {
                "application/json": {
                    /** Format: uuid */
                    clientActionID: string;
                };
            };
        };
        responses: {
            /** @description OK */
            200: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        code: string;
                        /** Format: date-time */
                        expiresAt: string;
                    };
                };
            };
            /** @description 401 */
            401: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "UNAUTHORIZED";
                        /** @constant */
                        status: 401;
                        /** @default The device session is missing, lapsed or revoked */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: false;
                        code: string;
                        status: number;
                        message: string;
                        data?: unknown;
                    };
                };
            };
            /** @description 409 */
            409: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "CLIENT_ACTION_ID_REUSED";
                        /** @constant */
                        status: 409;
                        /** @default The client action ID belongs to a different action */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: false;
                        code: string;
                        status: number;
                        message: string;
                        data?: unknown;
                    };
                };
            };
        };
    };
    "sessions.list": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        requestBody?: never;
        responses: {
            /** @description OK */
            200: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        sessions: {
                            /** Format: date-time */
                            createdAt: string;
                            current: boolean;
                            deviceName: string;
                            /** Format: date-time */
                            lastUsedAt: string;
                            /** Format: uuid */
                            sessionID: string;
                        }[];
                    };
                };
            };
            /** @description 401 */
            401: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "UNAUTHORIZED";
                        /** @constant */
                        status: 401;
                        /** @default The device session is missing, lapsed or revoked */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: false;
                        code: string;
                        status: number;
                        message: string;
                        data?: unknown;
                    };
                };
            };
        };
    };
    "sessions.revoke": {
        parameters: {
            query?: never;
            header?: never;
            path?: never;
            cookie?: never;
        };
        requestBody: {
            content: {
                "application/json": {
                    /** Format: uuid */
                    clientActionID: string;
                    /** Format: uuid */
                    sessionID: string;
                };
            };
        };
        responses: {
            /** @description OK */
            200: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** Format: date-time */
                        revokedAt: string;
                    };
                };
            };
            /** @description 401 */
            401: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "UNAUTHORIZED";
                        /** @constant */
                        status: 401;
                        /** @default The device session is missing, lapsed or revoked */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: false;
                        code: string;
                        status: number;
                        message: string;
                        data?: unknown;
                    };
                };
            };
            /** @description 404 */
            404: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "SESSION_NOT_FOUND";
                        /** @constant */
                        status: 404;
                        /** @default No session has this ID */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: false;
                        code: string;
                        status: number;
                        message: string;
                        data?: unknown;
                    };
                };
            };
            /** @description 409 */
            409: {
                headers: {
                    [name: string]: unknown;
                };
                content: {
                    "application/json": {
                        /** @constant */
                        defined: true;
                        /** @constant */
                        code: "CLIENT_ACTION_ID_REUSED";
                        /** @constant */
                        status: 409;
                        /** @default The client action ID belongs to a different action */
                        message: string;
                        data?: unknown;
                    } | {
                        /** @constant */
                        defined: false;
                        code: string;
                        status: number;
                        message: string;
                        data?: unknown;
                    };
                };
            };
        };
    };
}
