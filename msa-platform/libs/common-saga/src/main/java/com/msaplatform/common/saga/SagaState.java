package com.msaplatform.common.saga;

public enum SagaState {
    STARTED,
    IN_PROGRESS,
    COMPLETED,
    COMPENSATING,
    FAILED
}
