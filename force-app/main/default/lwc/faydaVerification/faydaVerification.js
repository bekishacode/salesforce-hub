import { LightningElement, api, wire, track } from 'lwc';
import { getRecord, getFieldValue, updateRecord } from 'lightning/uiRecordApi';
import { getRecordNotifyChange } from 'lightning/uiRecordApi';
import { refreshApex } from '@salesforce/apex';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import generateVerificationUrl from '@salesforce/apex/FaydaVerificationHandler.generateVerificationUrl';
import getUserInfoFromMuleSoft from '@salesforce/apex/FaydaVerificationHandler.getUserInfoFromMuleSoft';
import processVerificationResult from '@salesforce/apex/FaydaVerificationHandler.processVerificationResult';

// Import fields for record update
import STATUS_FIELD from '@salesforce/schema/Lead.FAYDA_Verification_Status__c';
import ID_FIELD from '@salesforce/schema/Lead.Id';

const FIELDS = [STATUS_FIELD];

export default class FaydaVerification extends LightningElement {
    @api recordId;
    
    // State management
    @track showVerifyButton = false;
    @track showTryAgainButton = false;
    @track showVerifiedStatus = false;
    @track isLoading = false;
    @track showConfirmationModal = false;
    @track showDetailsModal = false;
    @track showErrorModal = false;
    
    @track statusMessage = '';
    @track currentStatus = '';
    @track errorMessage = '';
    
    // Rate limiting
    @track verificationAttempts = 0;
    @track lastAttemptTime = null;
    @track rateLimitExceeded = false;
    @track timeRemaining = 0;
    
    // API response data
    @track userInfo = null;
    @track apiResponse = null;
    @track verificationDetails = {};
    
    // Popup monitoring
    popupWindow = null;
    currentState = null;
    
    // Constants
    MAX_ATTEMPTS = 3;
    TIME_WINDOW_MINUTES = 10;
    STORAGE_KEY_PREFIX = 'faydaAttempts_';
    
    // Wire result storage
    wiredRecordResult;

    @wire(getRecord, { recordId: '$recordId', fields: FIELDS })
    wiredRecord(result) {
        this.wiredRecordResult = result;
        const { data, error } = result;

        if (data) {
            const status = getFieldValue(data, STATUS_FIELD);
            this.currentStatus = status;
            this.updateButtonState(status);
        } else if (error) {
            console.error('Error loading lead record:', error);
            this.showError('Error loading lead record: ' + error.body?.message);
        }
    }

    // ========== TEMPLATE GETTERS ==========
    get timeRemainingFormatted() {
        const minutes = Math.floor(this.timeRemaining / 60);
        const seconds = this.timeRemaining % 60;
        return `${minutes}:${seconds.toString().padStart(2, '0')}`;
    }

    get isButtonDisabled() {
        return this.isLoading || this.rateLimitExceeded || this.showVerifiedStatus;
    }

    get buttonLabel() {
        if (this.rateLimitExceeded) {
            return `Try Again in ${this.timeRemainingFormatted}`;
        }
        return this.showTryAgainButton ? 'Try Again' : 'Verify Client';
    }

    get confirmButtonLabel() {
        return this.isLoading ? 'Processing...' : 'Confirm & Update Lead';
    }

    get formattedUserInfo() {
        if (!this.userInfo) return [];
        
        const info = [];
        
        // Basic info
        if (this.userInfo.name) info.push({ label: 'Full Name', value: this.userInfo.name });
        if (this.userInfo.email) info.push({ label: 'Email', value: this.userInfo.email });
        if (this.userInfo.phone_number) info.push({ label: 'Phone Number', value: this.userInfo.phone_number });
        if (this.userInfo.gender) info.push({ label: 'Gender', value: this.userInfo.gender });
        if (this.userInfo.nationality) info.push({ label: 'Nationality', value: this.userInfo.nationality });
        if (this.userInfo.birthdate) info.push({ label: 'Birthdate', value: this.userInfo.birthdate });
        if (this.userInfo.sub) info.push({ label: 'Fayda ID', value: this.userInfo.sub });
        
        // Address info
        if (this.userInfo.address) {
            const addr = this.userInfo.address;
            if (addr.region) info.push({ label: 'Region', value: addr.region });
            if (addr.woreda) info.push({ label: 'Woreda', value: addr.woreda });
            if (addr.zone) info.push({ label: 'Zone', value: addr.zone });
        }
        
        return info;
    }

    get apiResponseDetails() {
        if (!this.apiResponse) return '';
        return JSON.stringify(this.apiResponse, null, 2);
    }

    // ========== RATE LIMITING ==========
    connectedCallback() {
        this.checkRateLimit();
        this.startCountdownTimer();
    }

    disconnectedCallback() {
        this.stopCountdownTimer();
    }

    startCountdownTimer() {
        if (this.intervalId) {
            clearInterval(this.intervalId);
        }

        this.intervalId = setInterval(() => {
            if (this.status !== 'Verified' && this.rateLimitExceeded) {
                this.updateLiveCountdown();
            }
        }, 1000);
    }

    stopCountdownTimer() {
        if (this.intervalId) {
            clearInterval(this.intervalId);
            this.intervalId = null;
        }
    }

    updateLiveCountdown() {
        if (!this.rateLimitExceeded || this.currentStatus === 'Verified') {
            return;
        }

        const storageKey = this.STORAGE_KEY_PREFIX + this.recordId;
        const storedData = localStorage.getItem(storageKey);

        if (storedData) {
            const attempts = JSON.parse(storedData);
            const now = Date.now();
            const timeWindowMs = this.TIME_WINDOW_MINUTES * 60 * 1000;

            if (attempts.length > 0) {
                const oldestAttempt = Math.min(...attempts);
                const resetTime = oldestAttempt + timeWindowMs;
                const timeLeft = resetTime - now;

                if (timeLeft > 0) {
                    this.updateTimeUntilReset(timeLeft);
                } else {
                    this.checkRateLimit();
                }
            }
        }
    }

    checkRateLimit() {
        if (!this.recordId) {
            console.error('Lead ID is required for rate limiting');
            return;
        }

        if (this.currentStatus === 'Verified') {
            this.rateLimitExceeded = true;
            this.timeRemaining = '';
            this.stopCountdownTimer();
            return;
        }

        const storageKey = this.STORAGE_KEY_PREFIX + this.recordId;
        const storedData = localStorage.getItem(storageKey);

        if (!storedData) {
            this.verificationAttempts = this.MAX_ATTEMPTS;
            this.rateLimitExceeded = false;
            this.timeRemaining = '';
            return;
        }

        const attempts = JSON.parse(storedData);
        const now = Date.now();
        const timeWindowMs = this.TIME_WINDOW_MINUTES * 60 * 1000;

        const recentAttempts = attempts.filter(timestamp =>
            now - timestamp < timeWindowMs
        );

        if (recentAttempts.length !== attempts.length) {
            localStorage.setItem(storageKey, JSON.stringify(recentAttempts));
        }

        this.verificationAttempts = this.MAX_ATTEMPTS - recentAttempts.length;

        if (recentAttempts.length >= this.MAX_ATTEMPTS) {
            this.rateLimitExceeded = true;
            const oldestAttempt = Math.min(...recentAttempts);
            const resetTime = oldestAttempt + timeWindowMs;
            const timeLeft = resetTime - now;
            this.updateTimeUntilReset(timeLeft);
        } else {
            this.rateLimitExceeded = false;
            this.timeRemaining = '';
        }
    }

    updateTimeUntilReset(timeLeft) {
        if (timeLeft <= 0) {
            this.timeRemaining = '';
            return;
        }

        const minutes = Math.floor(timeLeft / (1000 * 60));
        const seconds = Math.floor((timeLeft % (1000 * 60)) / 1000);

        const formattedMinutes = minutes.toString().padStart(2, '0');
        const formattedSeconds = seconds.toString().padStart(2, '0');

        this.timeRemaining = `${formattedMinutes}:${formattedSeconds}`;
    }

    updateAttemptTracking() {
        const storageKey = this.STORAGE_KEY_PREFIX + this.recordId;
        const now = Date.now();
        const storedData = localStorage.getItem(storageKey);
        let attempts = storedData ? JSON.parse(storedData) : [];
        attempts.push(now);
        localStorage.setItem(storageKey, JSON.stringify(attempts));

        this.checkRateLimit();

        this.showToast('Verification Started', `Verification initiated. Remaining attempts: ${this.verificationAttempts}`, 'success');
    }

    // ========== MAIN VERIFICATION FLOW ==========
    updateButtonState(status) {
        this.showVerifyButton = false;
        this.showTryAgainButton = false;
        this.showVerifiedStatus = false;
        this.statusMessage = '';

        if (status === 'Verified' || status === 'Verification Successful' || status === 'Code Captured') {
            this.showVerifiedStatus = true;
            this.statusMessage = 'Client verified successfully';
        } else if (status === 'Pending' || status === 'Processing') {
            this.showTryAgainButton = true;
            this.statusMessage = 'Verification in progress. You can try again.';
        } else if (status === 'Verification Failed' || status === 'Cancelled') {
            this.showTryAgainButton = true;
            this.statusMessage = 'Verification failed. Please try again.';
        } else {
            this.showVerifyButton = true;
            this.statusMessage = 'Verify client using Fayda';
        }

        this.checkRateLimit();
    }

    async handleVerificationClick() {
        if (this.rateLimitExceeded) {
            this.showToast('Rate Limit Exceeded', `Please wait ${this.timeRemainingFormatted} before trying again.`, 'warning');
            return;
        }

        this.isLoading = true;
        this.errorMessage = '';
        
        try {
            this.updateAttemptTracking();

            const verificationUrl = await generateVerificationUrl({ leadId: this.recordId });
            
            this.currentState = this.extractStateFromUrl(verificationUrl);
            
            this.popupWindow = window.open(
                verificationUrl, 
                'faydaVerification', 
                'width=600,height=700,left=100,top=100'
            );
            
            if (!this.popupWindow) {
                throw new Error('Popup blocked! Please allow popups for this site.');
            }
            
            this.showToast('Success', 'Verification window opened. Please complete the process.', 'success');
            this.startPopupMonitoring();
            
        } catch (error) {
            console.error('Error starting verification:', error);
            this.errorMessage = error.message;
            this.showError('Failed to start verification: ' + error.message);
            this.isLoading = false;
        }
    }

    startPopupMonitoring() {
        const pollInterval = 1000;
        const maxAttempts = 120;
        let attempts = 0;
        
        const poll = setInterval(() => {
            attempts++;
            
            try {
                if (this.popupWindow.closed) {
                    clearInterval(poll);
                    if (attempts < 5) {
                        this.showToast('Info', 'Verification window was closed', 'info');
                    }
                    this.isLoading = false;
                    return;
                }
                
                const popupUrl = this.popupWindow.location.href;
                
                if (popupUrl.includes('verify.bank.com/verifyda20/getCode')) {
                    const urlParams = new URL(popupUrl).searchParams;
                    const code = urlParams.get('code');
                    const state = urlParams.get('state');
                    
                    if (code && state) {
                        console.log('Code captured automatically:', code);
                        clearInterval(poll);
                        this.popupWindow.close();
                        this.callMuleSoftAPI(code, state);
                        return;
                    }
                }
                
                if (popupUrl.includes('error=')) {
                    const urlParams = new URL(popupUrl).searchParams;
                    const error = urlParams.get('error');
                    clearInterval(poll);
                    this.popupWindow.close();
                    this.errorMessage = `Verification failed: ${error}`;
                    this.showError(this.errorMessage);
                    this.isLoading = false;
                    return;
                }
                
                if (attempts >= maxAttempts) {
                    clearInterval(poll);
                    this.popupWindow.close();
                    this.errorMessage = 'Verification timed out. Please try again.';
                    this.showError(this.errorMessage);
                    this.isLoading = false;
                    return;
                }
                
            } catch (error) {
                if (error.name === 'SecurityError') {
                    if (attempts >= maxAttempts) {
                        clearInterval(poll);
                        this.popupWindow.close();
                        this.errorMessage = 'Cannot access verification page. Please ensure popups are allowed.';
                        this.showError(this.errorMessage);
                        this.isLoading = false;
                    }
                }
            }
            
        }, pollInterval);
    }

    async callMuleSoftAPI(code, state) {
        try {
            console.log('Calling MuleSoft API with code:', code);
            
            const result = await getUserInfoFromMuleSoft({
                code: code,
                state: state
            });

            this.apiResponse = result;
            
            if (result.success) {
                this.userInfo = result.data || result;
                this.showConfirmationModal = true;
                this.showToast('Success', 'User information retrieved successfully. Please review and confirm.', 'success');
            } else {
                this.errorMessage = result.errorMessage || 'Failed to get user information';
                this.showError(this.errorMessage);
            }
            
            this.isLoading = false;
            
        } catch (error) {
            console.error('Error calling MuleSoft API:', error);
            this.errorMessage = error.body?.message || error.message;
            this.showError('Failed to call MuleSoft API: ' + this.errorMessage);
            this.isLoading = false;
        }
    }

    // ========== CONFIRMATION FLOW ==========
    async handleConfirm() {
        try {
            this.isLoading = true;
            
            // Update lead with verified information
            await this.updateLeadRecord(true);
            
            const result = await processVerificationResult({
                leadId: this.recordId,
                userInfo: this.userInfo,
                action: 'finish'
            });
            
            if (result.startsWith('SUCCESS')) {
                this.showToast('Success', 'Lead updated successfully with verified information!', 'success');
                this.showConfirmationModal = false;
                this.showDetailsModal = true; // Show details modal like KYC modal
                this.verificationDetails = this.userInfo;
                
                // Refresh the record data
                await this.refreshWireData();
            } else {
                throw new Error(result);
            }
            
        } catch (error) {
            console.error('Error confirming verification:', error);
            this.showError('Failed to update lead: ' + error.message);
        } finally {
            this.isLoading = false;
        }
    }

    async handleCancel() {
        try {
            this.isLoading = true;
            
            const result = await processVerificationResult({
                leadId: this.recordId,
                userInfo: null,
                action: 'cancel'
            });
            
            if (result.startsWith('SUCCESS')) {
                this.showToast('Info', 'Verification cancelled.', 'info');
                this.showConfirmationModal = false;
                this.userInfo = null;
                this.apiResponse = null;
                
                // Refresh the record data
                await this.refreshWireData();
            } else {
                throw new Error(result);
            }
            
        } catch (error) {
            console.error('Error cancelling verification:', error);
            this.showError('Failed to cancel verification: ' + error.message);
        } finally {
            this.isLoading = false;
        }
    }

    // ========== RECORD MANAGEMENT ==========
    async updateLeadRecord(isSuccessful) {
        try {
            const fields = {
                [ID_FIELD.fieldApiName]: this.recordId
            };

            if (isSuccessful && this.userInfo) {
                fields[STATUS_FIELD.fieldApiName] = 'Verified';
                
                // Map user info to lead fields
                if (this.userInfo.name) {
                    const nameParts = this.userInfo.name.split(' ');
                    fields['FirstName'] = nameParts[0] || '';
                    fields['LastName'] = nameParts.slice(1).join(' ') || nameParts[0] || '';
                }
                if (this.userInfo.email) fields['Email'] = this.userInfo.email;
                if (this.userInfo.phone_number) fields['MobilePhone'] = this.userInfo.phone_number;
                if (this.userInfo.gender) fields['Gender__c'] = this.userInfo.gender;
                if (this.userInfo.nationality) fields['Nationality__c'] = this.userInfo.nationality;
                if (this.userInfo.birthdate) {
                    // Format birthdate if needed
                    fields['Birth_of_date__c'] = this.userInfo.birthdate;
                }
                if (this.userInfo.sub) fields['FAYDA_Sub__c'] = this.userInfo.sub;
                
                // Address fields
                if (this.userInfo.address) {
                    const addr = this.userInfo.address;
                    if (addr.region) fields['Region__c'] = addr.region;
                    if (addr.woreda) fields['Woreda__c'] = addr.woreda;
                    if (addr.zone) fields['Zone__c'] = addr.zone;
                }
            } else {
                fields[STATUS_FIELD.fieldApiName] = 'Verification Failed';
            }

            const recordInput = { fields };
            await updateRecord(recordInput);

        } catch (error) {
            console.error('Error updating lead record:', error);
            throw new Error('Error updating lead record: ' + error.message);
        }
    }

    async refreshWireData() {
        try {
            if (this.wiredRecordResult) {
                await refreshApex(this.wiredRecordResult);
            }
            getRecordNotifyChange([{ recordId: this.recordId }]);
        } catch (error) {
            console.error('Error refreshing wire data:', error);
            getRecordNotifyChange([{ recordId: this.recordId }]);
        }
    }

    // ========== MODAL MANAGEMENT ==========
    closeConfirmationModal() {
        this.showConfirmationModal = false;
        this.userInfo = null;
        this.apiResponse = null;
    }

    closeDetailsModal() {
        this.showDetailsModal = false;
        this.verificationDetails = {};
    }

    closeErrorModal() {
        this.showErrorModal = false;
        this.errorMessage = '';
    }

    showError(message) {
        this.errorMessage = message;
        this.showErrorModal = true;
    }

    // ========== UTILITY METHODS ==========
    extractStateFromUrl(url) {
        try {
            const urlParams = new URL(url).searchParams;
            return urlParams.get('state');
        } catch (error) {
            console.error('Error extracting state from URL:', error);
            return null;
        }
    }

    showToast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({
            title: title,
            message: message,
            variant: variant
        }));
    }

    disconnectedCallback() {
        if (this.popupWindow && !this.popupWindow.closed) {
            this.popupWindow.close();
        }
        this.stopCountdownTimer();
    }
}