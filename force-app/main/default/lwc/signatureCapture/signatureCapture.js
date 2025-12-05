import { LightningElement, api, track, wire } from 'lwc';
import { getRecord } from 'lightning/uiRecordApi';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import saveSignature from '@salesforce/apex/SignatureController.saveSignature';

// Import Account fields if on Account page
import ACCOUNT_ID_FIELD from '@salesforce/schema/Account.Id';
import ACCOUNT_NAME_FIELD from '@salesforce/schema/Account.Name';

export default class SignatureCapture extends LightningElement {
    // This gets populated automatically when on Account record page
    @api recordId; // Will be Account ID when on Account page
    
    // Or pass directly if used elsewhere
    @api accountId;
    @api accountName;
    @api contactId;
    @api opportunityId;
    
    @track customerName = '';
    @track documentName = '';
    @track isLoading = false;
    @track statusMessage = '';
    @track statusClass = '';
    
    // Canvas variables
    canvas = null;
    ctx = null;
    isDrawing = false;
    lastX = 0;
    lastY = 0;
    hasSignature = false;
    
    // History for undo/redo
    history = [];
    historyIndex = -1;
    @track canUndo = false;
    @track canRedo = false;
    
    // Pen settings
    penColor = '#000000';
    penSize = 3;
    
    // Wire to get Account details if on Account page
    @wire(getRecord, { 
        recordId: '$recordId', 
        fields: [ACCOUNT_ID_FIELD, ACCOUNT_NAME_FIELD] 
    })
    wiredAccount({ error, data }) {
        if (data) {
            // If component is on Account page, use the Account ID
            this.accountId = this.recordId;
            this.accountName = data.fields.Name.value;
            
            // Auto-populate customer name with Account name
            if (!this.customerName && this.accountName) {
                this.customerName = this.accountName;
            }
        } else if (error) {
            console.error('Error loading account:', error);
            // Not on Account page, that's OK
        }
    }
    
    renderedCallback() {
        if (!this.canvas) {
            this.initializeCanvas();
            this.setupEventListeners();
        }
    }
    
    initializeCanvas() {
        this.canvas = this.template.querySelector('.signature-pad');
        this.ctx = this.canvas.getContext('2d');
        
        // Tablet-optimized size
        this.canvas.width = 800;
        this.canvas.height = 400;
        
        this.clearCanvas();
    }
    
    setupEventListeners() {
        // Mouse events
        this.canvas.addEventListener('mousedown', this.handleMouseDown.bind(this));
        this.canvas.addEventListener('mousemove', this.handleMouseMove.bind(this));
        this.canvas.addEventListener('mouseup', this.handleMouseUp.bind(this));
        
        // Touch events for tablet
        this.canvas.addEventListener('touchstart', this.handleTouchStart.bind(this), { passive: false });
        this.canvas.addEventListener('touchmove', this.handleTouchMove.bind(this), { passive: false });
        this.canvas.addEventListener('touchend', this.handleTouchEnd.bind(this), { passive: false });
    }
    
    // ========== DRAWING FUNCTIONS ==========
    clearCanvas() {
        this.ctx.fillStyle = 'white';
        this.ctx.fillRect(0, 0, this.canvas.width, this.canvas.height);
        this.ctx.strokeStyle = this.penColor;
        this.ctx.lineWidth = this.penSize;
        this.ctx.lineCap = 'round';
        this.ctx.lineJoin = 'round';
        this.hasSignature = false;
        this.saveToHistory();
    }
    
    handleMouseDown(e) {
        this.isDrawing = true;
        const rect = this.canvas.getBoundingClientRect();
        [this.lastX, this.lastY] = [e.offsetX, e.offsetY];
        this.saveToHistory();
    }
    
    handleMouseMove(e) {
        if (!this.isDrawing) return;
        this.draw(e.offsetX, e.offsetY);
    }
    
    handleMouseUp() {
        this.isDrawing = false;
    }
    
    // Touch events for tablet
    handleTouchStart(e) {
        e.preventDefault();
        this.isDrawing = true;
        const touch = e.touches[0];
        const rect = this.canvas.getBoundingClientRect();
        [this.lastX, this.lastY] = [
            touch.clientX - rect.left,
            touch.clientY - rect.top
        ];
        this.saveToHistory();
    }
    
    handleTouchMove(e) {
        e.preventDefault();
        if (!this.isDrawing) return;
        const touch = e.touches[0];
        const rect = this.canvas.getBoundingClientRect();
        this.draw(touch.clientX - rect.left, touch.clientY - rect.top);
    }
    
    handleTouchEnd(e) {
        e.preventDefault();
        this.isDrawing = false;
    }
    
    draw(x, y) {
        this.ctx.beginPath();
        this.ctx.moveTo(this.lastX, this.lastY);
        this.ctx.lineTo(x, y);
        this.ctx.stroke();
        [this.lastX, this.lastY] = [x, y];
        this.hasSignature = true;
    }
    
    saveToHistory() {
        const imageData = this.ctx.getImageData(0, 0, this.canvas.width, this.canvas.height);
        this.history = this.history.slice(0, this.historyIndex + 1);
        this.history.push(imageData);
        this.historyIndex++;
        this.updateUndoRedoButtons();
    }
    
    // ========== CONTROLS ==========
    clearSignature() {
        this.clearCanvas();
    }
    
    undo() {
        if (this.historyIndex > 0) {
            this.historyIndex--;
            this.ctx.putImageData(this.history[this.historyIndex], 0, 0);
            this.hasSignature = this.historyIndex > 0;
            this.updateUndoRedoButtons();
        }
    }
    
    redo() {
        if (this.historyIndex < this.history.length - 1) {
            this.historyIndex++;
            this.ctx.putImageData(this.history[this.historyIndex], 0, 0);
            this.hasSignature = true;
            this.updateUndoRedoButtons();
        }
    }
    
    updateUndoRedoButtons() {
        this.canUndo = this.historyIndex > 0;
        this.canRedo = this.historyIndex < this.history.length - 1;
    }
    
    handleColorChange(e) {
        this.penColor = e.target.value;
        this.ctx.strokeStyle = this.penColor;
    }
    
    handleSizeChange(e) {
        this.penSize = parseInt(e.target.value);
        this.ctx.lineWidth = this.penSize;
    }
    
    // ========== INPUT HANDLERS ==========
    handleCustomerNameChange(e) {
        this.customerName = e.target.value;
    }
    
    handleDocumentNameChange(e) {
        this.documentName = e.target.value;
    }
    
    // ========== VALIDATION ==========
    // Add these getters to your component class

    get disableUndo() {
        return !this.canUndo;
    }

    get disableRedo() {
        return !this.canRedo;
    }

    get disableSave() {
        // Return true to disable, false to enable
        return !this.isReadyToSave || this.isLoading;
    }

    get isReadyToSave() {
        return this.hasSignature && this.documentName;
    }
    
   
    // ========== MAIN SAVE FUNCTION ==========
    async saveSignature() {
        try {
            this.isLoading = true;
            this.showStatus('Processing signature...', 'info');
            
            // Validate
            if (!this.documentName) {
                throw new Error('Document name is required');
            }
            
            if (!this.hasSignature) {
                throw new Error('Please provide a signature');
            }
            
            // Convert canvas to Base64
            const dataUrl = this.canvas.toDataURL('image/png');
            const base64Data = dataUrl.split(',')[1];
            
            // Prepare metadata
            const metadata = {
                documentName: this.documentName,
                customerName: this.customerName,
                accountName: this.accountName,
                accountId: this.accountId,
                timestamp: new Date().toISOString(),
                capturedBy: 'Tablet Signature Capture'
            };
            
            // Save signature - Pass Account ID to Apex
            const result = await saveSignature({
                accountId: this.accountId,
                contactId: this.contactId,
                opportunityId: this.opportunityId,
                customerName: this.customerName,
                documentName: this.documentName,
                signatureData: base64Data,
                metadata: JSON.stringify(metadata)
            });
            
            // Show success
            this.showStatus('Signature saved successfully!', 'success');
            
            // Dispatch event with the created record ID
            this.dispatchEvent(new CustomEvent('signaturesaved', {
                detail: {
                    recordId: result.recordId,
                    fileName: result.fileName,
                    accountId: this.accountId,
                    accountName: this.accountName,
                    status: 'success'
                }
            }));
            
            // Reset for next signature
            this.resetForm();
            
        } catch (error) {
            console.error('Error saving signature:', error);
            this.showStatus(`Error: ${error.body?.message || error.message}`, 'error');
        } finally {
            this.isLoading = false;
        }
    }
    
    // ========== UTILITIES ==========
    showStatus(message, type) {
        this.statusMessage = message;
        this.statusClass = `status-${type}`;
        
        if (type === 'success') {
            setTimeout(() => {
                this.statusMessage = '';
            }, 3000);
        }
    }
    
    resetForm() {
        this.clearCanvas();
        this.documentName = '';
        // Don't clear customerName if it came from Account
        if (!this.accountName) {
            this.customerName = '';
        }
    }
}